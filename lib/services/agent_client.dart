/// RPC client for the Personal AI Agent.
///
/// The agent runs as a separate Dart CLI process (see `agent/`) under the
/// SAME Atsign as this user, listening in the isolated `agent` RPC domain of
/// the `scytale` namespace. Requests/responses use the built-in
/// AtRpcClient, which rides on atProtocol notifications.
library;

import 'package:at_client/at_client.dart';

import '../core/constants.dart';

class AgentClient {
  AgentClient._();
  static final AgentClient instance = AgentClient._();

  AtRpcClient? _rpcClient;
  String? _forAtsign;

  AtRpcClient _client() {
    final atClient = AtClientManager.getInstance().atClient;
    final me = atClient.getCurrentAtSign()!.toAtsign();
    // Rebuild if the signed-in Atsign changed (logout/login).
    if (_rpcClient == null || _forAtsign != me) {
      _rpcClient = AtRpcClient(
        serverAtsign: me, // the agent shares our Atsign
        atClient: atClient,
        baseNameSpace: appNamespace,
        domainNameSpace: agentRpcDomain,
      );
      _forAtsign = me;
    }
    return _rpcClient!;
  }

  /// Send a method call to the agent. Throws [TimeoutException] when the
  /// agent process is not running / unreachable.
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 90),
  }) {
    return _client().call({
      'method': method,
      'params': params ?? {},
    }).timeout(timeout);
  }

  Future<Map<String, dynamic>> whatDidIMiss({int? sinceTs}) =>
      call('what_did_i_miss', params: {'sinceTs': ?sinceTs});

  Future<Map<String, dynamic>> summarize({String? peer, int? sinceTs}) =>
      call('summarize', params: {'peer': ?peer, 'sinceTs': ?sinceTs});

  Future<Map<String, dynamic>> actionItems({String? peer, int? sinceTs}) =>
      call('action_items', params: {'peer': ?peer, 'sinceTs': ?sinceTs});
}
