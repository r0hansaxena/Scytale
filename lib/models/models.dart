/// Data models for the Scytale app.
///
/// Every model here is serialized to JSON and stored as an AtKey value —
/// never in local files — so it syncs across all of the owner's devices.
library;

/// Local-only delivery state of an outbound message (not serialized).
enum DeliveryStatus {
  /// Being written / notified.
  sending,

  /// Durably stored on our atServer (fire-and-forget put succeeded);
  /// the peer will receive it when they next connect.
  stored,

  /// Notification confirmed delivered to the peer's atServer.
  delivered,

  /// Both put and notify failed.
  failed,
}

/// A single chat message. Stored as `msg.<id>.scytale` shared with the
/// peer; the receiver keeps a self-copy under `recv.<id>.scytale`.
class ChatMessage {
  final String id;
  final String from;
  final String to;
  final String text;
  final int ts; // epoch millis (sender clock)
  final String? replyTo; // id of the message this replies to
  final bool edited;
  final bool deleted; // tombstone: history slot preserved, content removed
  final String kind; // 'text' | 'call' | 'image' | 'file'
  // Attachment metadata (kind == 'image' | 'file'). The bytes live in a
  // separate `file.<id>` key, fetched lazily; only the metadata rides here.
  final String? fileName;
  final String? mime;
  final int? fileSize;

  const ChatMessage({
    required this.id,
    required this.from,
    required this.to,
    required this.text,
    required this.ts,
    this.replyTo,
    this.edited = false,
    this.deleted = false,
    this.kind = 'text',
    this.fileName,
    this.mime,
    this.fileSize,
  });

  bool get isCallEntry => kind == 'call';
  bool get isAttachment => kind == 'image' || kind == 'file';

  ChatMessage copyWith({String? text, bool? edited, bool? deleted}) =>
      ChatMessage(
        id: id,
        from: from,
        to: to,
        text: text ?? this.text,
        ts: ts,
        replyTo: replyTo,
        edited: edited ?? this.edited,
        deleted: deleted ?? this.deleted,
        kind: kind,
        fileName: fileName,
        mime: mime,
        fileSize: fileSize,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'from': from,
        'to': to,
        'text': text,
        'ts': ts,
        if (replyTo != null) 'replyTo': replyTo,
        'edited': edited,
        'deleted': deleted,
        if (kind != 'text') 'kind': kind,
        if (fileName != null) 'fileName': fileName,
        if (mime != null) 'mime': mime,
        if (fileSize != null) 'fileSize': fileSize,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        from: json['from'] as String,
        to: json['to'] as String,
        text: json['text'] as String? ?? '',
        ts: json['ts'] as int,
        replyTo: json['replyTo'] as String?,
        edited: json['edited'] as bool? ?? false,
        deleted: json['deleted'] as bool? ?? false,
        kind: json['kind'] as String? ?? 'text',
        fileName: json['fileName'] as String?,
        mime: json['mime'] as String?,
        fileSize: json['fileSize'] as int?,
      );
}

/// An emoji reaction to a message. Stored as `rct.<msgId>.<emojiId>.scytale`
/// shared with the peer. Removing a reaction re-puts with `removed: true`.
class Reaction {
  final String msgId;
  final String emoji;
  final String by;
  final int ts;
  final bool removed;

  const Reaction({
    required this.msgId,
    required this.emoji,
    required this.by,
    required this.ts,
    this.removed = false,
  });

  /// Deterministic key-safe id for an emoji (hex of its code units).
  static String emojiId(String emoji) =>
      emoji.runes.map((r) => r.toRadixString(16)).join('_');

  Map<String, dynamic> toJson() => {
        'msgId': msgId,
        'emoji': emoji,
        'by': by,
        'ts': ts,
        'removed': removed,
      };

  factory Reaction.fromJson(Map<String, dynamic> json) => Reaction(
        msgId: json['msgId'] as String,
        emoji: json['emoji'] as String,
        by: json['by'] as String,
        ts: json['ts'] as int? ?? 0,
        removed: json['removed'] as bool? ?? false,
      );
}

/// Read-receipt watermark shared with a peer:
/// "I have read everything you sent up to [lastReadTs]".
class ReadReceipt {
  final String conversationWith;
  final int lastReadTs;

  const ReadReceipt({required this.conversationWith, required this.lastReadTs});

  Map<String, dynamic> toJson() =>
      {'conversationWith': conversationWith, 'lastReadTs': lastReadTs};

  factory ReadReceipt.fromJson(Map<String, dynamic> json) => ReadReceipt(
        conversationWith: json['conversationWith'] as String,
        lastReadTs: json['lastReadTs'] as int? ?? 0,
      );
}

/// Lightweight public profile, stored as the public key `profile.scytale`.
class Profile {
  final String name;
  final String bio;
  final String? avatarB64;

  const Profile({this.name = '', this.bio = '', this.avatarB64});

  Map<String, dynamic> toJson() => {
        'name': name,
        'bio': bio,
        if (avatarB64 != null) 'avatarB64': avatarB64,
      };

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        name: json['name'] as String? ?? '',
        bio: json['bio'] as String? ?? '',
        avatarB64: json['avatarB64'] as String?,
      );
}
