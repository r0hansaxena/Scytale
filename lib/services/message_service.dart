/// Messaging core: sends/receives chat data as encrypted AtKeys and keeps
/// in-memory conversation state for the UI.
///
/// Transport (per the platform patterns):
///  - Outbound: `atClient.put()` for durable fire-and-forget storage, plus
///    `notificationService.notify()` for real-time delivery with a
///    NotificationResult that drives the delivery status shown in the UI.
///  - Inbound: a single `notificationService.subscribe()` on the
///    "(msg|rct|read) dot anything dot scytale@" pattern with
///    `shouldDecrypt: true`.
///    The monitor replays notifications missed while offline; an additional
///    startup sweep scans each known peer's atServer for message keys we have
///    not ingested yet.
///
/// Storage (never local files — AtKeys only, so everything syncs):
///  - `msg.<id>.scytale`             sharedWith peer   outbound message
///  - `rct.<msgId>.<emojiId>.scytale` sharedWith peer  reaction add/remove
///  - `read.<peerNoAt>.scytale`      sharedWith peer   read-receipt watermark
///  - `recvmsg.<id>.scytale`         self              copy of inbound message
///  - `recvrct.<...>.scytale`        self              copy of inbound reaction
///  - `recvread.<fromNoAt>.scytale`  self              copy of inbound receipt
///  - `myread.<peerNoAt>.scytale`    self              my read position
///  - `fav.<msgId>.scytale`          self              favorite flag
library;

import 'dart:async';
import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../models/models.dart';

const _uuid = Uuid();

/// Per-peer conversation state held in memory for the UI.
class ConversationState {
  final String peer;
  final Map<String, ChatMessage> messagesById = {};
  /// msgId -> (`<emojiId>:<by>` -> Reaction), removed reactions excluded.
  final Map<String, Map<String, Reaction>> reactions = {};
  int peerLastReadTs = 0; // how far the peer has read our messages
  int myLastReadTs = 0; // how far we have read theirs

  ConversationState(this.peer);

  List<ChatMessage> get sortedMessages =>
      messagesById.values.toList()..sort((a, b) => a.ts.compareTo(b.ts));

  ChatMessage? get lastMessage {
    final msgs = sortedMessages;
    return msgs.isEmpty ? null : msgs.last;
  }

  int unreadCount(String me) => messagesById.values
      .where((m) => m.from != me && !m.deleted && m.ts > myLastReadTs)
      .length;
}

class MessageService extends ChangeNotifier {
  MessageService._();
  static final MessageService instance = MessageService._();

  AtClient get _atClient => AtClientManager.getInstance().atClient;
  late Atsign me;

  final Map<String, ConversationState> conversations = {};
  final Map<String, DeliveryStatus> statuses = {};
  final Set<String> favorites = {};

  StreamSubscription<AtNotification>? _subscription;
  bool _started = false;

  ConversationState _conversation(String peer) =>
      conversations.putIfAbsent(peer, () => ConversationState(peer));

  /// Call once after setCurrentAtSign: loads history from local AtKeys,
  /// subscribes to live notifications, and sweeps peers for missed messages.
  Future<void> start() async {
    me = _atClient.getCurrentAtSign()!.toAtsign();
    conversations.clear();
    statuses.clear();
    favorites.clear();
    _attachmentCache.clear();

    await _loadLocalHistory();

    _subscription?.cancel();
    _subscription = _atClient.notificationService
        .subscribe(
            regex: '(msg|rct|read)\\..*\\.$appNamespace@',
            shouldDecrypt: true)
        .listen(_onNotification,
            onError: (e) => debugPrint('notification stream error: $e'));

    notifyListeners();

    // Belt-and-braces catch-up: the monitor replays missed notifications,
    // but they can expire; scan each known peer's atServer for message keys
    // we have not seen. Non-fatal if a peer is unreachable.
    unawaited(_sweepAllPeers());
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _started = false;
    conversations.clear();
    statuses.clear();
    favorites.clear();
    _attachmentCache.clear();
  }

  bool get isStarted => _started;

  // ---------------------------------------------------------------------
  // Outbound operations
  // ---------------------------------------------------------------------

  AtKey _sharedKey(String keyName, String peer) => AtKey()
    ..key = keyName
    ..namespace = appNamespace
    ..sharedBy = me
    ..sharedWith = peer
    ..metadata = (Metadata()..isEncrypted = true);

  AtKey _selfKey(String keyName) => AtKey()
    ..key = keyName
    ..namespace = appNamespace
    ..sharedBy = me;

  /// Durable put + real-time notify. Returns true if the data is at least
  /// stored on our atServer (fire-and-forget delivery guaranteed).
  Future<bool> _putAndNotify(AtKey key, String json,
      {void Function(bool delivered)? onDelivery}) async {
    var stored = false;
    try {
      stored = await _atClient.put(key, json);
    } on AtClientException catch (e) {
      debugPrint('put failed for $key: $e');
    }
    // Notify asynchronously so the UI is not blocked while waiting for the
    // final delivery status.
    unawaited(() async {
      try {
        final result = await _atClient.notificationService.notify(
          NotificationParams.forUpdate(key, value: json),
          checkForFinalDeliveryStatus: true,
          waitForFinalDeliveryStatus: true,
        );
        onDelivery?.call(
            result.notificationStatusEnum == NotificationStatusEnum.delivered);
      } catch (e) {
        debugPrint('notify failed for $key: $e');
        onDelivery?.call(false);
      }
    }());
    return stored;
  }

  Future<void> sendMessage(String peerRaw, String text,
      {String? replyTo, String kind = 'text'}) async {
    final peer = peerRaw.toAtsign();
    final msg = ChatMessage(
      id: _uuid.v4(),
      from: me,
      to: peer,
      text: text,
      ts: DateTime.now().millisecondsSinceEpoch,
      replyTo: replyTo,
      kind: kind,
    );
    _conversation(peer).messagesById[msg.id] = msg;
    statuses[msg.id] = DeliveryStatus.sending;
    notifyListeners();

    final stored = await _putAndNotify(
      _sharedKey('msg.${msg.id}', peer),
      jsonEncode(msg.toJson()),
      onDelivery: (delivered) {
        // If not delivered we keep 'stored': the peer still gets it later
        // via sync or the offline sweep.
        if (delivered) statuses[msg.id] = DeliveryStatus.delivered;
        notifyListeners();
      },
    );
    if (statuses[msg.id] == DeliveryStatus.sending) {
      statuses[msg.id] = stored ? DeliveryStatus.stored : DeliveryStatus.failed;
    }
    notifyListeners();
  }

  DeliveryStatus statusOf(String msgId) =>
      statuses[msgId] ?? DeliveryStatus.stored;

  // ---------------------------------------------------------------------
  // Attachments (images / files)
  //
  // Bytes are base64'd into a separate `file.<id>` key (written straight to
  // the cloud so the peer can fetch it immediately); the `msg.<id>` message
  // carries only lightweight metadata and drives the bubble. atServer value
  // size limits mean this suits images/docs/short clips, not large videos.
  // ---------------------------------------------------------------------

  static const int maxAttachmentBytes = 1500 * 1024; // ~1.5 MB

  final Map<String, Uint8List> _attachmentCache = {};

  /// Sends [bytes] as an attachment. Returns null on success, or an
  /// error message (e.g. too large) to show the user.
  Future<String?> sendAttachment(
      String peerRaw, Uint8List bytes, String fileName, String mime) async {
    if (bytes.length > maxAttachmentBytes) {
      return 'File is too large (${formatSize(bytes.length)}). '
          'Attachments are limited to ${formatSize(maxAttachmentBytes)}.';
    }
    final peer = peerRaw.toAtsign();
    final id = _uuid.v4();
    final kind = mime.startsWith('image/') ? 'image' : 'file';
    final msg = ChatMessage(
      id: id,
      from: me,
      to: peer,
      text: fileName,
      ts: DateTime.now().millisecondsSinceEpoch,
      kind: kind,
      fileName: fileName,
      mime: mime,
      fileSize: bytes.length,
    );
    _attachmentCache[id] = bytes;
    _conversation(peer).messagesById[id] = msg;
    statuses[id] = DeliveryStatus.sending;
    notifyListeners();

    // 1. Store the bytes on the cloud secondary so the peer can fetch them
    //    the moment the metadata message wakes them.
    var bytesStored = false;
    try {
      await _atClient.put(
        _sharedKey('file.$id', peer),
        base64Encode(bytes),
        putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
      );
      bytesStored = true;
    } on AtClientException catch (e) {
      debugPrint('attachment bytes put failed: $e');
    }
    if (!bytesStored) {
      statuses[id] = DeliveryStatus.failed;
      notifyListeners();
      return 'Failed to upload the attachment. Check your connection.';
    }

    // 2. Store + notify the metadata message (drives the bubble + inbox).
    final metaStored = await _putAndNotify(
      _sharedKey('msg.$id', peer),
      jsonEncode(msg.toJson()),
      onDelivery: (delivered) {
        if (delivered) statuses[id] = DeliveryStatus.delivered;
        notifyListeners();
      },
    );
    if (statuses[id] == DeliveryStatus.sending) {
      statuses[id] = metaStored ? DeliveryStatus.stored : DeliveryStatus.failed;
    }
    notifyListeners();
    return null;
  }

  /// Lazily fetch (and cache) the bytes for an attachment message.
  Future<Uint8List?> loadAttachment(ChatMessage msg) async {
    final cached = _attachmentCache[msg.id];
    if (cached != null) return cached;
    try {
      final AtKey key;
      if (msg.from == me) {
        key = _sharedKey('file.${msg.id}', msg.to);
      } else {
        key = AtKey()
          ..key = 'file.${msg.id}'
          ..namespace = appNamespace
          ..sharedBy = msg.from.toAtsign()
          ..sharedWith = me;
      }
      final res = await _atClient.get(key);
      if (res.value == null) return null;
      final bytes = base64Decode(res.value as String);
      _attachmentCache[msg.id] = bytes;
      return bytes;
    } catch (e) {
      debugPrint('loadAttachment failed for ${msg.id}: $e');
      return null;
    }
  }

  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _updateOwnMessage(ChatMessage updated) async {
    final peer = updated.to;
    _conversation(peer).messagesById[updated.id] = updated;
    notifyListeners();
    await _putAndNotify(
      _sharedKey('msg.${updated.id}', peer),
      jsonEncode(updated.toJson()),
    );
  }

  Future<void> editMessage(String peer, String msgId, String newText) async {
    final msg = _conversation(peer.toAtsign()).messagesById[msgId];
    if (msg == null || msg.from != me || msg.deleted) return;
    await _updateOwnMessage(msg.copyWith(text: newText, edited: true));
  }

  /// Delete = tombstone: the message slot is preserved, content removed.
  Future<void> deleteMessage(String peer, String msgId) async {
    final msg = _conversation(peer.toAtsign()).messagesById[msgId];
    if (msg == null || msg.from != me) return;
    await _updateOwnMessage(msg.copyWith(text: '', deleted: true));
  }

  Future<void> toggleReaction(String peerRaw, String msgId, String emoji) async {
    final peer = peerRaw.toAtsign();
    final emojiId = Reaction.emojiId(emoji);
    final conv = _conversation(peer);
    final existing = conv.reactions[msgId]?['$emojiId:$me'];
    final reaction = Reaction(
      msgId: msgId,
      emoji: emoji,
      by: me,
      ts: DateTime.now().millisecondsSinceEpoch,
      removed: existing != null,
    );
    _applyReaction(peer, reaction);
    notifyListeners();
    await _putAndNotify(
      _sharedKey('rct.$msgId.$emojiId', peer),
      jsonEncode(reaction.toJson()),
    );
  }

  /// Mark the conversation with [peerRaw] read up to its latest inbound
  /// message: persists my read position (self key, syncs across my devices)
  /// and shares a read-receipt watermark with the peer.
  Future<void> markRead(String peerRaw) async {
    final peer = peerRaw.toAtsign();
    final conv = _conversation(peer);
    final latestInbound = conv.messagesById.values
        .where((m) => m.from != me)
        .fold<int>(0, (acc, m) => m.ts > acc ? m.ts : acc);
    if (latestInbound <= conv.myLastReadTs) return;
    conv.myLastReadTs = latestInbound;
    notifyListeners();

    final receipt =
        ReadReceipt(conversationWith: peer, lastReadTs: latestInbound);
    final json = jsonEncode(receipt.toJson());
    try {
      await _atClient.put(_selfKey('myread.${peer.withoutAt()}'), json);
    } on AtClientException catch (e) {
      debugPrint('failed to persist read position: $e');
    }
    await _putAndNotify(_sharedKey('read.${peer.withoutAt()}', peer), json);
  }

  Future<void> toggleFavorite(String msgId) async {
    final key = _selfKey('fav.$msgId');
    try {
      if (favorites.contains(msgId)) {
        favorites.remove(msgId);
        notifyListeners();
        await _atClient.delete(key);
      } else {
        favorites.add(msgId);
        notifyListeners();
        await _atClient.put(
            key,
            jsonEncode({
              'msgId': msgId,
              'ts': DateTime.now().millisecondsSinceEpoch
            }));
      }
    } on AtClientException catch (e) {
      debugPrint('favorite toggle failed: $e');
    }
  }

  /// Open (or surface) a conversation with a peer.
  void openConversation(String peerRaw) {
    final peer = peerRaw.toAtsign();
    if (peer == me) {
      throw InvalidAtSignException('Cannot start a chat with yourself');
    }
    _conversation(peer);
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Inbound: live notifications
  // ---------------------------------------------------------------------

  Future<void> _onNotification(AtNotification notification) async {
    try {
      final from = notification.from.toAtsign();
      if (from == me) return; // our own RPC/agent traffic is not chat data
      final value = notification.value;
      if (value == null || value.isEmpty) return;

      // notification.key looks like '@me:msg.<id>.scytale@peer'
      final name = notification.key
          .replaceFirst('${notification.to}:', '')
          .split('.$appNamespace')
          .first;

      if (name.startsWith('msg.')) {
        final msg = ChatMessage.fromJson(jsonDecode(value));
        await _ingestMessage(from, msg, storeCopy: true);
      } else if (name.startsWith('rct.')) {
        final reaction = Reaction.fromJson(jsonDecode(value));
        _applyReaction(from, reaction);
        await _storeSelfCopy(
            'recvrct.${reaction.msgId}.${Reaction.emojiId(reaction.emoji)}.${from.withoutAt()}',
            value);
      } else if (name.startsWith('read.')) {
        final receipt = ReadReceipt.fromJson(jsonDecode(value));
        _conversation(from).peerLastReadTs = receipt.lastReadTs;
        await _storeSelfCopy('recvread.${from.withoutAt()}', value);
      } else {
        return;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('failed to handle notification ${notification.key}: $e');
    }
  }

  Future<void> _ingestMessage(String peer, ChatMessage msg,
      {required bool storeCopy}) async {
    final existing = _conversation(peer).messagesById[msg.id];
    // Idempotent: overwrite (edits/tombstones re-use the id; last value wins).
    _conversation(peer).messagesById[msg.id] = msg;
    if (storeCopy && (existing == null || existing.text != msg.text ||
        existing.deleted != msg.deleted || existing.edited != msg.edited)) {
      await _storeSelfCopy('recvmsg.${msg.id}', jsonEncode(msg.toJson()));
    }
  }

  void _applyReaction(String peer, Reaction reaction) {
    final byEmoji = _conversation(peer)
        .reactions
        .putIfAbsent(reaction.msgId, () => {});
    final slot = '${Reaction.emojiId(reaction.emoji)}:${reaction.by}';
    if (reaction.removed) {
      byEmoji.remove(slot);
    } else {
      byEmoji[slot] = reaction;
    }
  }

  /// Store an inbound item as a self AtKey so it syncs to all of our devices.
  Future<void> _storeSelfCopy(String keyName, String json) async {
    try {
      await _atClient.put(_selfKey(keyName), json);
    } on AtClientException catch (e) {
      debugPrint('failed to store self copy $keyName: $e');
    }
  }

  // ---------------------------------------------------------------------
  // History load + offline sweep
  // ---------------------------------------------------------------------

  Future<void> _loadLocalHistory() async {
    List<AtKey> keys;
    try {
      keys = await _atClient.getAtKeys(regex: appNamespace);
    } on AtClientException catch (e) {
      debugPrint('local key scan failed: $e');
      return;
    }

    for (final key in keys) {
      final name = key.key;
      try {
        if (name.startsWith('msg.') && key.sharedWith != null) {
          // A message we sent.
          final value = (await _atClient.get(key)).value;
          if (value == null) continue;
          final msg = ChatMessage.fromJson(jsonDecode(value));
          _conversation(key.sharedWith!.toAtsign()).messagesById[msg.id] = msg;
        } else if (name.startsWith('recvmsg.')) {
          final value = (await _atClient.get(key)).value;
          if (value == null) continue;
          final msg = ChatMessage.fromJson(jsonDecode(value));
          _conversation(msg.from.toAtsign()).messagesById[msg.id] = msg;
        } else if (name.startsWith('rct.') && key.sharedWith != null) {
          final value = (await _atClient.get(key)).value;
          if (value == null) continue;
          _applyReaction(
              key.sharedWith!.toAtsign(), Reaction.fromJson(jsonDecode(value)));
        } else if (name.startsWith('recvrct.')) {
          final value = (await _atClient.get(key)).value;
          if (value == null) continue;
          final reaction = Reaction.fromJson(jsonDecode(value));
          _applyReaction(reaction.by.toAtsign(), reaction);
        } else if (name.startsWith('myread.')) {
          final value = (await _atClient.get(key)).value;
          if (value == null) continue;
          final receipt = ReadReceipt.fromJson(jsonDecode(value));
          _conversation(receipt.conversationWith.toAtsign()).myLastReadTs =
              receipt.lastReadTs;
        } else if (name.startsWith('recvread.')) {
          final value = (await _atClient.get(key)).value;
          if (value == null) continue;
          final receipt = ReadReceipt.fromJson(jsonDecode(value));
          // Receipt sender is encoded in the key name suffix.
          final fromNoAt = name.substring('recvread.'.length);
          _conversation('@$fromNoAt'.toAtsign()).peerLastReadTs =
              receipt.lastReadTs;
        } else if (name.startsWith('fav.')) {
          favorites.add(name.substring('fav.'.length));
        }
      } catch (e) {
        debugPrint('skipping unreadable key $key: $e');
      }
    }
    _started = true;
  }

  Future<void> _sweepAllPeers() async {
    for (final peer in conversations.keys.toList()) {
      await sweepPeer(peer);
    }
    notifyListeners();
  }

  /// Scan [peer]'s atServer for message/reaction keys shared with us that we
  /// have not ingested (e.g. sent while we were offline and the notification
  /// expired before our monitor reconnected).
  Future<void> sweepPeer(String peerRaw) async {
    final peer = peerRaw.toAtsign();
    List<AtKey> keys;
    try {
      keys = await _atClient.getAtKeys(
          regex: 'msg\\..*\\.$appNamespace', sharedBy: peer);
    } catch (e) {
      debugPrint('sweep of $peer failed (peer offline is fine): $e');
      return;
    }
    var changed = false;
    for (final key in keys) {
      try {
        final id = key.key.split('.')[1];
        if (_conversation(peer).messagesById.containsKey(id)) continue;
        final value = (await _atClient.get(key)).value;
        if (value == null) continue;
        final msg = ChatMessage.fromJson(jsonDecode(value));
        await _ingestMessage(peer, msg, storeCopy: true);
        changed = true;
      } catch (e) {
        debugPrint('sweep: could not fetch $key: $e');
      }
    }
    if (changed) notifyListeners();
  }
}
