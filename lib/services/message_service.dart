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

/// Per-conversation state held in memory for the UI. [peer] is the other
/// Atsign for a 1:1 chat, or the group id for a group chat.
class ConversationState {
  final String peer;
  final bool isGroup;
  String displayName;
  List<String> members; // group members (empty for 1:1)
  final Map<String, ChatMessage> messagesById = {};
  /// msgId -> (`<emojiId>:<by>` -> Reaction), removed reactions excluded.
  final Map<String, Map<String, Reaction>> reactions = {};
  int peerLastReadTs = 0; // how far the peer has read our messages
  int myLastReadTs = 0; // how far we have read theirs

  ConversationState(this.peer,
      {this.isGroup = false, String? displayName, List<String>? members})
      : displayName = displayName ?? peer,
        members = members ?? const [];

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

  /// Peers whose conversation is archived (hidden from the main inbox).
  /// Persisted as the self key `archived.scytale`.
  final Set<String> archived = {};

  /// Known groups by id.
  final Map<String, Group> groups = {};

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
    archived.clear();
    groups.clear();
    _attachmentCache.clear();

    await _loadGroups(); // before history, so group messages route correctly
    await _loadLocalHistory();
    await _loadArchived();

    _subscription?.cancel();
    _subscription = _atClient.notificationService
        .subscribe(
            regex: '(msg|rct|read|grp)\\..*\\.$appNamespace@',
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
    archived.clear();
    _attachmentCache.clear();
  }

  bool get isStarted => _started;

  // ---------------------------------------------------------------------
  // Conversation management (archive / delete / read state)
  // ---------------------------------------------------------------------

  bool isArchived(String peerRaw) => archived.contains(peerRaw.toAtsign());

  Future<void> toggleArchive(String peerRaw) async {
    final peer = peerRaw.toAtsign();
    if (!archived.remove(peer)) archived.add(peer);
    notifyListeners();
    await _saveArchived();
  }

  Future<void> _loadArchived() async {
    try {
      final value = (await _atClient.get(_selfKey('archived'))).value;
      if (value != null) {
        archived
          ..clear()
          ..addAll((jsonDecode(value) as List).map((e) => e.toString()));
      }
    } catch (_) {
      // No archive list yet.
    }
  }

  Future<void> _saveArchived() async {
    try {
      await _atClient.put(_selfKey('archived'), jsonEncode(archived.toList()));
    } on AtClientException catch (e) {
      debugPrint('failed to save archive list: $e');
    }
  }

  /// Reset our read watermark so the conversation shows as unread.
  Future<void> markUnread(String convId) async {
    final conv = _convFor(convId);
    conv.myLastReadTs = 0;
    notifyListeners();
    if (conv.isGroup) return;
    final peer = convId.toAtsign();
    try {
      await _atClient.put(
        _selfKey('myread.${peer.withoutAt()}'),
        jsonEncode(ReadReceipt(conversationWith: peer, lastReadTs: 0).toJson()),
      );
    } on AtClientException catch (e) {
      debugPrint('failed to mark unread: $e');
    }
  }

  /// Delete the conversation for us: drop it from memory and best-effort
  /// delete all of our own AtKeys that belong to it. For a group this also
  /// removes our group metadata and leaves the group for us.
  Future<void> deleteConversation(String convId) async {
    if (groups.containsKey(convId)) {
      await _deleteGroupConversation(convId);
      return;
    }
    final peer = convId.toAtsign();
    conversations.remove(peer);
    archived.remove(peer);
    notifyListeners();
    unawaited(_saveArchived());

    final peerNoAt = peer.withoutAt();
    List<AtKey> keys;
    try {
      keys = await _atClient.getAtKeys(regex: appNamespace);
    } on AtClientException catch (e) {
      debugPrint('deleteConversation scan failed: $e');
      return;
    }
    for (final key in keys) {
      final name = key.key;
      var remove = false;
      if (key.sharedWith != null && key.sharedWith!.toAtsign() == peer) {
        // msg./rct./read. we shared with this peer.
        remove = true;
      } else if (name == 'myread.$peerNoAt' || name == 'recvread.$peerNoAt') {
        remove = true;
      } else if (name.startsWith('recvmsg.') || name.startsWith('recvrct.')) {
        // Id-based self copies — read to see if the counterparty is this peer.
        try {
          final value = (await _atClient.get(key)).value;
          if (value != null) {
            final m = (jsonDecode(value) as Map).cast<String, dynamic>();
            final other = (m['from'] ?? m['by'])?.toString();
            if (other != null && other.toAtsign() == peer) remove = true;
          }
        } catch (_) {}
      }
      if (remove) {
        try {
          await _atClient.delete(key);
        } catch (_) {}
      }
    }
  }

  Future<void> _deleteGroupConversation(String groupId) async {
    final group = groups.remove(groupId);
    conversations.remove(groupId);
    archived.remove(groupId);
    notifyListeners();
    unawaited(_saveArchived());
    if (group == null) return;

    List<AtKey> keys;
    try {
      keys = await _atClient.getAtKeys(regex: appNamespace);
    } on AtClientException catch (e) {
      debugPrint('group delete scan failed: $e');
      return;
    }
    for (final key in keys) {
      final name = key.key;
      var remove = false;
      if (name == 'grp.$groupId') {
        remove = true; // our metadata copies (self + shared)
      } else if (name.startsWith('msg.') ||
          name.startsWith('recvmsg.') ||
          name.startsWith('rct.') ||
          name.startsWith('recvrct.')) {
        try {
          final value = (await _atClient.get(key)).value;
          if (value != null) {
            final m = (jsonDecode(value) as Map).cast<String, dynamic>();
            if (m['groupId'] == groupId) remove = true;
          }
        } catch (_) {}
      }
      if (remove) {
        try {
          await _atClient.delete(key);
        } catch (_) {}
      }
    }
  }

  // ---------------------------------------------------------------------
  // Groups
  // ---------------------------------------------------------------------

  ConversationState _groupConversation(Group g) =>
      conversations.putIfAbsent(
          g.id,
          () => ConversationState(g.id,
              isGroup: true, displayName: g.name, members: g.members));

  /// Create a group and share its metadata with every other member.
  Future<String> createGroup(String name, List<String> memberRaws) async {
    final members = <String>{me, ...memberRaws.map((m) => m.toAtsign())}
        .toList();
    final group = Group(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? 'Group' : name.trim(),
      members: members,
      createdBy: me,
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    groups[group.id] = group;
    _groupConversation(group);
    notifyListeners();

    final json = jsonEncode(group.toJson());
    // Self copy (syncs to my other devices).
    try {
      await _atClient.put(_selfKey('grp.${group.id}'), json);
    } on AtClientException catch (e) {
      debugPrint('failed to store own group copy: $e');
    }
    // Share with every other member.
    for (final member in members) {
      if (member == me) continue;
      await _putAndNotify(_sharedKey('grp.${group.id}', member), json);
    }
    return group.id;
  }

  Future<void> _loadGroups() async {
    List<AtKey> keys;
    try {
      keys = await _atClient.getAtKeys(regex: 'grp\\..*\\.$appNamespace');
    } on AtClientException catch (e) {
      debugPrint('group scan failed: $e');
      return;
    }
    for (final key in keys) {
      try {
        final value = (await _atClient.get(key)).value;
        if (value == null) continue;
        _ingestGroup(Group.fromJson(jsonDecode(value)));
      } catch (e) {
        debugPrint('skipping unreadable group key $key: $e');
      }
    }
  }

  void _ingestGroup(Group g) {
    groups[g.id] = g;
    final conv = _groupConversation(g);
    conv.displayName = g.name;
    conv.members = g.members;
  }

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

  /// Recipients for a conversation id: the single peer for a 1:1, or every
  /// other group member (fan-out) for a group.
  List<String> _recipients(String convId) {
    final g = groups[convId];
    if (g != null) return g.members.where((m) => m != me).toList();
    return [convId.toAtsign()];
  }

  ConversationState _convFor(String convId) {
    final g = groups[convId];
    return g != null
        ? _groupConversation(g)
        : _conversation(convId.toAtsign());
  }

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

  Future<void> sendMessage(String convId, String text,
      {String? replyTo, String kind = 'text'}) async {
    final group = groups[convId];
    final id = _uuid.v4();
    final msg = ChatMessage(
      id: id,
      from: me,
      to: group != null ? convId : convId.toAtsign(),
      text: text,
      ts: DateTime.now().millisecondsSinceEpoch,
      replyTo: replyTo,
      kind: kind,
      groupId: group?.id,
    );
    _convFor(convId).messagesById[id] = msg;
    statuses[id] = DeliveryStatus.sending;
    notifyListeners();

    final json = jsonEncode(msg.toJson());
    final recipients = _recipients(convId);
    if (group != null) {
      // Fan out to each member; use a simple stored/failed status for groups.
      var anyStored = false;
      for (final r in recipients) {
        anyStored = await _putAndNotify(_sharedKey('msg.$id', r), json) ||
            anyStored;
      }
      statuses[id] = anyStored ? DeliveryStatus.stored : DeliveryStatus.failed;
      notifyListeners();
    } else {
      final stored = await _putAndNotify(
        _sharedKey('msg.$id', recipients.first),
        json,
        onDelivery: (delivered) {
          if (delivered) statuses[id] = DeliveryStatus.delivered;
          notifyListeners();
        },
      );
      if (statuses[id] == DeliveryStatus.sending) {
        statuses[id] = stored ? DeliveryStatus.stored : DeliveryStatus.failed;
      }
      notifyListeners();
    }
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
      String convId, Uint8List bytes, String fileName, String mime) async {
    if (bytes.length > maxAttachmentBytes) {
      return 'File is too large (${formatSize(bytes.length)}). '
          'Attachments are limited to ${formatSize(maxAttachmentBytes)}.';
    }
    final group = groups[convId];
    final id = _uuid.v4();
    final kind = mime.startsWith('image/') ? 'image' : 'file';
    final msg = ChatMessage(
      id: id,
      from: me,
      to: group != null ? convId : convId.toAtsign(),
      text: fileName,
      ts: DateTime.now().millisecondsSinceEpoch,
      kind: kind,
      fileName: fileName,
      mime: mime,
      fileSize: bytes.length,
      groupId: group?.id,
    );
    _attachmentCache[id] = bytes;
    _convFor(convId).messagesById[id] = msg;
    statuses[id] = DeliveryStatus.sending;
    notifyListeners();

    final b64 = base64Encode(bytes);
    final metaJson = jsonEncode(msg.toJson());
    var anyStored = false;
    for (final r in _recipients(convId)) {
      // 1. Upload the bytes to the cloud so the recipient can fetch them.
      try {
        await _atClient.put(
          _sharedKey('file.$id', r),
          b64,
          putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
        );
      } on AtClientException catch (e) {
        debugPrint('attachment bytes put failed for $r: $e');
        continue;
      }
      // 2. Send the metadata message that drives the bubble.
      anyStored = await _putAndNotify(_sharedKey('msg.$id', r), metaJson) ||
          anyStored;
    }
    statuses[id] = anyStored ? DeliveryStatus.stored : DeliveryStatus.failed;
    notifyListeners();
    return anyStored
        ? null
        : 'Failed to upload the attachment. Check your connection.';
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

  Future<void> _updateOwnMessage(String convId, ChatMessage updated) async {
    _convFor(convId).messagesById[updated.id] = updated;
    notifyListeners();
    final json = jsonEncode(updated.toJson());
    for (final r in _recipients(convId)) {
      await _putAndNotify(_sharedKey('msg.${updated.id}', r), json);
    }
  }

  Future<void> editMessage(String convId, String msgId, String newText) async {
    final msg = _convFor(convId).messagesById[msgId];
    if (msg == null || msg.from != me || msg.deleted) return;
    await _updateOwnMessage(convId, msg.copyWith(text: newText, edited: true));
  }

  /// Delete = tombstone: the message slot is preserved, content removed.
  Future<void> deleteMessage(String convId, String msgId) async {
    final msg = _convFor(convId).messagesById[msgId];
    if (msg == null || msg.from != me) return;
    await _updateOwnMessage(convId, msg.copyWith(text: '', deleted: true));
  }

  Future<void> toggleReaction(String convId, String msgId, String emoji) async {
    final emojiId = Reaction.emojiId(emoji);
    final conv = _convFor(convId);
    final existing = conv.reactions[msgId]?['$emojiId:$me'];
    final reaction = Reaction(
      msgId: msgId,
      emoji: emoji,
      by: me,
      ts: DateTime.now().millisecondsSinceEpoch,
      removed: existing != null,
    );
    _applyReaction(conv.peer, reaction);
    notifyListeners();
    final json = jsonEncode(reaction.toJson());
    for (final r in _recipients(convId)) {
      await _putAndNotify(_sharedKey('rct.$msgId.$emojiId', r), json);
    }
  }

  /// Mark a conversation read up to its latest inbound message. For 1:1 chats
  /// this also shares a read-receipt watermark with the peer; groups just
  /// update the local read position.
  Future<void> markRead(String convId) async {
    final conv = _convFor(convId);
    final latestInbound = conv.messagesById.values
        .where((m) => m.from != me)
        .fold<int>(0, (acc, m) => m.ts > acc ? m.ts : acc);
    if (latestInbound <= conv.myLastReadTs) return;
    conv.myLastReadTs = latestInbound;
    notifyListeners();
    if (conv.isGroup) return; // no per-member receipts for groups

    final peer = conv.peer.toAtsign();
    final peerNoAt = peer.withoutAt();
    final receipt =
        ReadReceipt(conversationWith: peer, lastReadTs: latestInbound);
    final json = jsonEncode(receipt.toJson());
    try {
      await _atClient.put(_selfKey('myread.$peerNoAt'), json);
    } on AtClientException catch (e) {
      debugPrint('failed to persist read position: $e');
    }
    await _putAndNotify(_sharedKey('read.$peerNoAt', peer), json);
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

      if (name.startsWith('grp.')) {
        _ingestGroup(Group.fromJson(jsonDecode(value)));
        await _storeSelfCopy(name, value); // keep a synced self copy
      } else if (name.startsWith('msg.')) {
        final msg = ChatMessage.fromJson(jsonDecode(value));
        // Route group messages to the group; 1:1 to the sender's conversation.
        await _ingestMessage(msg.groupId ?? from, msg, storeCopy: true);
      } else if (name.startsWith('rct.')) {
        final reaction = Reaction.fromJson(jsonDecode(value));
        _applyReaction(_reactionConvId(reaction, from), reaction);
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

  /// Route an inbound message into the right conversation. Group messages go
  /// to the group (by msg.groupId); 1:1 messages go to [convIdHint] (the
  /// sender). If a group message arrives before its metadata, a placeholder
  /// group conversation is created.
  ConversationState _conversationForMessage(String convIdHint, ChatMessage msg) {
    if (msg.groupId != null) {
      final g = groups[msg.groupId];
      if (g != null) return _groupConversation(g);
      return conversations.putIfAbsent(
          msg.groupId!,
          () => ConversationState(msg.groupId!,
              isGroup: true, displayName: 'Group'));
    }
    return _conversation(convIdHint.toAtsign());
  }

  Future<void> _ingestMessage(String convIdHint, ChatMessage msg,
      {required bool storeCopy}) async {
    final conv = _conversationForMessage(convIdHint, msg);
    final existing = conv.messagesById[msg.id];
    // Idempotent: overwrite (edits/tombstones re-use the id; last value wins).
    conv.messagesById[msg.id] = msg;
    if (storeCopy && (existing == null || existing.text != msg.text ||
        existing.deleted != msg.deleted || existing.edited != msg.edited)) {
      await _storeSelfCopy('recvmsg.${msg.id}', jsonEncode(msg.toJson()));
    }
  }

  /// Which conversation a reaction belongs to: the group/1:1 that holds the
  /// target message, else the sender's 1:1.
  String _reactionConvId(Reaction reaction, String from) {
    for (final conv in conversations.values) {
      if (conv.messagesById.containsKey(reaction.msgId)) return conv.peer;
    }
    return from;
  }

  void _applyReaction(String convId, Reaction reaction) {
    final conv = groups.containsKey(convId)
        ? _groupConversation(groups[convId]!)
        : _conversation(convId.toAtsign());
    final byEmoji = conv.reactions.putIfAbsent(reaction.msgId, () => {});
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
        if (name.startsWith('grp.')) {
          // handled in _loadGroups
          continue;
        } else if (name.startsWith('msg.') && key.sharedWith != null) {
          // A message we sent.
          final value = (await _atClient.get(key)).value;
          if (value == null) continue;
          final msg = ChatMessage.fromJson(jsonDecode(value));
          _conversationForMessage(key.sharedWith!.toAtsign(), msg)
              .messagesById[msg.id] = msg;
        } else if (name.startsWith('recvmsg.')) {
          final value = (await _atClient.get(key)).value;
          if (value == null) continue;
          final msg = ChatMessage.fromJson(jsonDecode(value));
          _conversationForMessage(msg.from.toAtsign(), msg)
              .messagesById[msg.id] = msg;
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
    for (final conv in conversations.values.toList()) {
      if (conv.isGroup) continue; // group messages arrive via notifications
      await sweepPeer(conv.peer);
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
