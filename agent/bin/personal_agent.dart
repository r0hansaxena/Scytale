/// Personal AI Agent for the Scytale app.
///
/// Runs as a separate Dart CLI process under the SAME Atsign as its owner,
/// in a dedicated RPC domain (`agent.__rpcs.scytale`) for strict namespace
/// isolation. It answers three RPC methods, invoked by the Flutter app:
///
///   - what_did_i_miss {sinceTs?}         digest of unread messages
///   - summarize       {peer?, sinceTs?}  conversation summary
///   - action_items    {peer?, sinceTs?}  extracted action items
///
/// Intelligence: when ANTHROPIC_API_KEY is set, the agent calls the Claude
/// Messages API (model claude-opus-4-8 by default, override with AGENT_MODEL).
/// Without a key it degrades to a deterministic heuristic digest, so the RPC
/// pipeline always works. The response payload's `mode` field reports which
/// path produced it.
///
/// Security:
///   - allowList = {owner atsign} — only the owner can invoke it.
///   - Reads only the owner's own message keys; no cross-user inference.
///   - Multi-instance safe: AtRpc's built-in request mutex (an immutable key
///     with TTL, written with useRemoteAtServer) ensures exactly one instance
///     handles each request; each instance uses a unique hive storage path.
///
/// Usage:
///   dart run bin/personal_agent.dart -a @alice
///   (keys are read from ~/.atsign/keys/@alice_key.atKeys, or pass -k)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_cli_commons/at_cli_commons.dart';
// at_commons (re-exported by at_client) defines its own StringBuffer;
// hide it so dart:core's StringBuffer is used.
import 'package:at_client/at_client.dart' hide StringBuffer;
import 'package:at_utils/at_logger.dart';
import 'package:http/http.dart' as http;

const String appNamespace = 'scytale';
const String agentRpcDomain = 'agent';
const String defaultModel = 'claude-opus-4-8';

final AtSignLogger logger = AtSignLogger('personal_agent');

Future<void> main(List<String> args) async {
  AtSignLogger.root_level = 'warning';

  // Default the mandatory namespace, and give this instance a unique local
  // storage path unless one was supplied — two agent processes sharing a
  // hive path would collide and throw.
  final effectiveArgs = List<String>.of(args);
  if (!args.contains('-n') && !args.any((a) => a.startsWith('--namespace'))) {
    effectiveArgs.addAll(['-n', appNamespace]);
  }
  if (!args.contains('-s') && !args.any((a) => a.startsWith('--storage-dir'))) {
    effectiveArgs.addAll(
        ['-s', Directory.systemTemp.createTempSync('scytale_agent_').path]);
  }

  late final CLIBase cli;
  try {
    cli = await CLIBase.fromCommandLineArgs(effectiveArgs);
  } catch (e) {
    stderr.writeln('Failed to authenticate: $e');
    stderr.writeln(CLIBase.argsParser.usage);
    exit(1);
  }

  final atClient = cli.atClient;
  final me = atClient.getCurrentAtSign()!.toAtsign();

  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  final mode = (apiKey != null && apiKey.isNotEmpty) ? 'claude' : 'heuristic';
  stdout.writeln('Personal AI Agent running for $me '
      '(intelligence: $mode). Waiting for requests — Ctrl-C to stop.');

  final agent = PersonalAgent(atClient, me, apiKey);
  final rpc = AtRpc(
    atClient: atClient,
    baseNameSpace: appNamespace,
    domainNameSpace: agentRpcDomain,
    callbacks: agent,
    allowList: {me}, // strict: only the owner may invoke this agent
    isClient: false,
    isServer: true,
    // Immutable-mutex race (TTL-backed, written with useRemoteAtServer) so
    // only one agent instance handles each request.
    enableRequestMutex: true,
  );
  rpc.start();

  // Keep the process alive.
  await Completer<void>().future;
}

class PersonalAgent implements AtRpcCallbacks {
  final AtClient atClient;
  final String owner;
  final String? anthropicApiKey;

  PersonalAgent(this.atClient, this.owner, this.anthropicApiKey);

  @override
  Future<AtRpcResp> handleRequest(AtRpcReq request, String fromAtSign) async {
    stdout.writeln('[${DateTime.now()}] request ${request.reqId} '
        'from $fromAtSign: ${request.payload['method']}');
    try {
      final method = request.payload['method'] as String? ?? '';
      final params = (request.payload['params'] as Map?)
              ?.cast<String, dynamic>() ??
          <String, dynamic>{};

      final result = switch (method) {
        'what_did_i_miss' => await _whatDidIMiss(params),
        'summarize' => await _summarize(params),
        'action_items' => await _actionItems(params),
        _ => throw ArgumentError('Unknown method: $method'),
      };
      return AtRpcResp(
        reqId: request.reqId,
        respType: AtRpcRespType.success,
        payload: result,
      );
    } catch (e, st) {
      logger.severe('request ${request.reqId} failed: $e\n$st');
      return AtRpcResp(
        reqId: request.reqId,
        respType: AtRpcRespType.error,
        payload: {'error': e.toString()},
        message: e.toString(),
      );
    }
  }

  @override
  Future<void> handleResponse(AtRpcResp response) async {
    // Server only; responses are not expected.
  }

  // -----------------------------------------------------------------------
  // Data access — reads ONLY the owner's own keys in the scytale namespace
  // -----------------------------------------------------------------------

  /// Loads chat messages from the owner's atServer:
  /// `recvmsg.*` self-copies (inbound) and `msg.*` sharedWith keys (outbound).
  Future<List<Map<String, dynamic>>> _loadMessages(
      {String? peer, int? sinceTs}) async {
    final messages = <Map<String, dynamic>>[];
    List<AtKey> keys;
    try {
      // Scan the remote atServer directly: the agent's local storage is
      // ephemeral and may not have synced yet.
      keys = await atClient.getAtKeys(
          regex: '(recvmsg|msg)\\..*\\.$appNamespace', useRemoteAtServer: true);
    } on AtClientException catch (e) {
      logger.warning('remote scan failed, falling back to local: $e');
      keys = await atClient.getAtKeys(
          regex: '(recvmsg|msg)\\..*\\.$appNamespace');
    }

    for (final key in keys) {
      final isOutbound = key.key.startsWith('msg.') && key.sharedWith != null;
      final isInbound = key.key.startsWith('recvmsg.');
      if (!isOutbound && !isInbound) continue;
      try {
        final value = (await atClient.get(key,
                getRequestOptions: GetRequestOptions()..bypassCache = true))
            .value;
        if (value == null) continue;
        final msg = (jsonDecode(value) as Map).cast<String, dynamic>();
        if (msg['deleted'] == true) continue;
        final other = isOutbound ? msg['to'] : msg['from'];
        if (peer != null && other != peer) continue;
        if (sinceTs != null && (msg['ts'] as int? ?? 0) <= sinceTs) continue;
        messages.add(msg);
      } catch (e) {
        logger.warning('skipping unreadable key $key: $e');
      }
    }
    messages.sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    return messages;
  }

  /// Read positions: peer atsign -> last-read timestamp (from `myread.*`).
  Future<Map<String, int>> _loadReadPositions() async {
    final positions = <String, int>{};
    try {
      final keys = await atClient.getAtKeys(
          regex: 'myread\\..*\\.$appNamespace', useRemoteAtServer: true);
      for (final key in keys) {
        try {
          final value = (await atClient.get(key)).value;
          if (value == null) continue;
          final receipt = (jsonDecode(value) as Map).cast<String, dynamic>();
          positions[receipt['conversationWith'] as String] =
              receipt['lastReadTs'] as int? ?? 0;
        } catch (_) {}
      }
    } catch (e) {
      logger.warning('could not load read positions: $e');
    }
    return positions;
  }

  // -----------------------------------------------------------------------
  // RPC methods
  // -----------------------------------------------------------------------

  Future<Map<String, dynamic>> _whatDidIMiss(
      Map<String, dynamic> params) async {
    final sinceTs = params['sinceTs'] as int?;
    final readPositions = await _loadReadPositions();
    final all = await _loadMessages(sinceTs: sinceTs);

    // Unread = inbound and newer than my read watermark for that peer.
    final unread = all.where((m) {
      final from = m['from'] as String;
      if (from == owner) return false;
      return (m['ts'] as int) > (readPositions[from] ?? 0);
    }).toList();

    if (unread.isEmpty) {
      return {'result': 'You are all caught up — no unread messages.',
              'mode': 'heuristic'};
    }
    return _answer(
      task: 'The user asked: "What did I miss?". Summarize the unread '
          'messages below per sender, most important first. Be brief.',
      messages: unread,
      heuristic: () => _heuristicDigest(unread),
    );
  }

  Future<Map<String, dynamic>> _summarize(Map<String, dynamic> params) async {
    final messages = await _loadMessages(
        peer: params['peer'] as String?, sinceTs: params['sinceTs'] as int?);
    if (messages.isEmpty) {
      return {'result': 'No messages found to summarize.', 'mode': 'heuristic'};
    }
    return _answer(
      task: 'Summarize the conversation(s) below: main topics, decisions, '
          'and anything requiring the user\'s attention.',
      messages: messages,
      heuristic: () => _heuristicSummary(messages),
    );
  }

  Future<Map<String, dynamic>> _actionItems(
      Map<String, dynamic> params) async {
    final messages = await _loadMessages(
        peer: params['peer'] as String?, sinceTs: params['sinceTs'] as int?);
    if (messages.isEmpty) {
      return {'result': 'No messages found.', 'mode': 'heuristic'};
    }
    return _answer(
      task: 'Extract the user\'s action items from the messages below as a '
          'checklist: what needs doing, requested by whom, any deadline. '
          'If there are none, say so.',
      messages: messages,
      heuristic: () => _heuristicActionItems(messages),
    );
  }

  // -----------------------------------------------------------------------
  // Intelligence: Claude API with heuristic fallback
  // -----------------------------------------------------------------------

  Future<Map<String, dynamic>> _answer({
    required String task,
    required List<Map<String, dynamic>> messages,
    required String Function() heuristic,
  }) async {
    if (anthropicApiKey == null || anthropicApiKey!.isEmpty) {
      return {'result': heuristic(), 'mode': 'heuristic'};
    }
    try {
      final result = await _askClaude(task, _transcript(messages));
      return {'result': result, 'mode': 'claude'};
    } catch (e) {
      logger.warning('Claude API failed, using heuristic fallback: $e');
      return {
        'result': '${heuristic()}\n\n(note: Claude API unavailable: $e)',
        'mode': 'heuristic',
      };
    }
  }

  String _transcript(List<Map<String, dynamic>> messages) {
    // Cap the transcript at the most recent 300 messages.
    final recent = messages.length > 300
        ? messages.sublist(messages.length - 300)
        : messages;
    final buf = StringBuffer();
    for (final m in recent) {
      final ts = DateTime.fromMillisecondsSinceEpoch(m['ts'] as int);
      final from = m['from'] == owner ? 'me' : m['from'];
      final to = m['to'] == owner ? 'me' : m['to'];
      buf.writeln('[$ts] $from -> $to: ${m['text']}');
    }
    return buf.toString();
  }

  Future<String> _askClaude(String task, String transcript) async {
    final model = Platform.environment['AGENT_MODEL'] ?? defaultModel;
    final response = await http
        .post(
          Uri.parse('https://api.anthropic.com/v1/messages'),
          headers: {
            'content-type': 'application/json',
            'x-api-key': anthropicApiKey!,
            'anthropic-version': '2023-06-01',
          },
          body: jsonEncode({
            'model': model,
            'max_tokens': 2048,
            'system':
                'You are the personal messaging assistant of $owner inside a '
                'private, end-to-end encrypted chat app. You only ever see '
                'this one user\'s own messages. Answer plainly and concisely; '
                'these are private conversations, treat them respectfully.',
            'messages': [
              {
                'role': 'user',
                'content': '$task\n\n<messages>\n$transcript</messages>',
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw HttpException(
          'Claude API returned ${response.statusCode}: ${response.body}');
    }
    final body = (jsonDecode(response.body) as Map).cast<String, dynamic>();
    if (body['stop_reason'] == 'refusal') {
      throw StateError('Claude declined the request');
    }
    final content = (body['content'] as List).cast<Map<String, dynamic>>();
    return content
        .where((block) => block['type'] == 'text')
        .map((block) => block['text'])
        .join('\n');
  }

  // -----------------------------------------------------------------------
  // Deterministic heuristics (no LLM required)
  // -----------------------------------------------------------------------

  String _heuristicDigest(List<Map<String, dynamic>> unread) {
    final byPeer = <String, List<Map<String, dynamic>>>{};
    for (final m in unread) {
      byPeer.putIfAbsent(m['from'] as String, () => []).add(m);
    }
    final buf = StringBuffer('You have ${unread.length} unread message'
        '${unread.length == 1 ? '' : 's'} from ${byPeer.length} '
        'conversation${byPeer.length == 1 ? '' : 's'}:\n');
    byPeer.forEach((peer, msgs) {
      final latest = msgs.last;
      buf.writeln('\n• $peer (${msgs.length}): '
          '"${_preview(latest['text'] as String)}"');
    });
    return buf.toString().trimRight();
  }

  String _heuristicSummary(List<Map<String, dynamic>> messages) {
    final peers = <String>{};
    for (final m in messages) {
      peers.add(m['from'] == owner ? m['to'] as String : m['from'] as String);
    }
    final first = DateTime.fromMillisecondsSinceEpoch(messages.first['ts']);
    final last = DateTime.fromMillisecondsSinceEpoch(messages.last['ts']);
    final buf = StringBuffer(
        '${messages.length} messages with ${peers.join(', ')} '
        'between $first and $last.\n\nMost recent:\n');
    for (final m in messages.reversed.take(5)) {
      final who = m['from'] == owner ? 'me' : m['from'];
      buf.writeln('• $who: "${_preview(m['text'] as String)}"');
    }
    return buf.toString().trimRight();
  }

  static final RegExp _actionPattern = RegExp(
      r'\b(can you|could you|will you|would you|please|need to|needs to|'
      r"don'?t forget|remember to|todo|to-do|make sure|by (monday|tuesday|"
      r'wednesday|thursday|friday|saturday|sunday|tomorrow|tonight|eod|eow))\b',
      caseSensitive: false);

  String _heuristicActionItems(List<Map<String, dynamic>> messages) {
    final items = <String>[];
    for (final m in messages) {
      final text = m['text'] as String;
      if (_actionPattern.hasMatch(text) || text.trim().endsWith('?')) {
        final who = m['from'] == owner ? 'me' : m['from'];
        items.add('☐ ($who) ${_preview(text, 120)}');
      }
    }
    if (items.isEmpty) return 'No obvious action items found.';
    return 'Possible action items:\n${items.join('\n')}';
  }

  String _preview(String text, [int max = 80]) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= max ? oneLine : '${oneLine.substring(0, max)}…';
  }
}
