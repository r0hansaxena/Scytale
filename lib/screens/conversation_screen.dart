import 'dart:io';

import 'package:at_client/at_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';
import '../services/call_service.dart';
import '../services/message_service.dart';
import '../services/profile_service.dart';
import '../widgets/avatar.dart';

const _quickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🎉'];

/// Delivery-status indicator for our own messages. A deliberately distinct
/// convention (not WhatsApp's blue double-tick):
///   sending   → rotating spinner
///   sent      → single check      (on our atServer)
///   delivered → double check      (on the peer's atServer)
///   read      → filled check-circle in the accent colour
///   failed    → error glyph
Widget deliveryIndicator(
    BuildContext context, DeliveryStatus status, bool read) {
  final theme = Theme.of(context);
  final muted = theme.colorScheme.onSurfaceVariant;
  if (read && status != DeliveryStatus.failed && status != DeliveryStatus.sending) {
    return Icon(Icons.check_circle, size: 14, color: theme.colorScheme.primary);
  }
  switch (status) {
    case DeliveryStatus.sending:
      return const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.6),
      );
    case DeliveryStatus.failed:
      return Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error);
    case DeliveryStatus.stored:
      return Icon(Icons.check, size: 14, color: muted);
    case DeliveryStatus.delivered:
      return Icon(Icons.done_all, size: 14, color: muted);
  }
}

/// 1:1 conversation view: message list, composer, reactions, replies,
/// edit/delete, favorites, delivery/read status.
class ConversationScreen extends StatefulWidget {
  final String peer;
  const ConversationScreen({super.key, required this.peer});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final MessageService _messages = MessageService.instance;
  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();

  ChatMessage? _replyingTo;
  ChatMessage? _editing;

  String get _me =>
      AtClientManager.getInstance().atClient.getCurrentAtSign() ?? '';

  @override
  void initState() {
    super.initState();
    _messages.addListener(_onUpdate);
    ProfileService.instance.addListener(_onUpdate);
    // Pull the latest profile (name/photo/bio) each time a 1:1 chat is opened.
    if (!(_messages.conversations[widget.peer]?.isGroup ?? false)) {
      ProfileService.instance.fetch(widget.peer, refresh: true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _messages.markRead(widget.peer);
    });
  }

  @override
  void dispose() {
    _messages.removeListener(_onUpdate);
    ProfileService.instance.removeListener(_onUpdate);
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  void _onUpdate() {
    if (!mounted) return;
    setState(() {});
    // New inbound messages are read while this screen is open.
    _messages.markRead(widget.peer);
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    final editing = _editing;
    final replyingTo = _replyingTo;
    setState(() {
      _composer.clear();
      _replyingTo = null;
      _editing = null;
    });
    if (editing != null) {
      await _messages.editMessage(widget.peer, editing.id, text);
    } else {
      await _messages.sendMessage(widget.peer, text, replyTo: replyingTo?.id);
    }
  }

  Future<void> _attachFile() async {
    final result = await FilePicker.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    final bytes = f.bytes;
    if (bytes == null) return;
    final error = await _messages.sendAttachment(
        widget.peer, bytes, f.name, _guessMime(f.extension));
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  static String _guessMime(String? ext) {
    switch (ext?.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'pdf':
        return 'application/pdf';
      case 'mp4':
        return 'video/mp4';
      case 'mp3':
        return 'audio/mpeg';
      default:
        return 'application/octet-stream';
    }
  }

  void _showMessageActions(ChatMessage msg) {
    final isMine = msg.from == _me;
    final isFavorite = _messages.favorites.contains(msg.id);
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final emoji in _quickEmojis)
                    InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _messages.toggleReaction(widget.peer, msg.id, emoji);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(emoji,
                            style: const TextStyle(fontSize: 28)),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(sheetContext);
                setState(() {
                  _replyingTo = msg;
                  _editing = null;
                });
                _composerFocus.requestFocus();
              },
            ),
            ListTile(
              leading: Icon(isFavorite ? Icons.star : Icons.star_border),
              title: Text(isFavorite ? 'Remove favorite' : 'Favorite'),
              onTap: () {
                Navigator.pop(sheetContext);
                _messages.toggleFavorite(msg.id);
              },
            ),
            if (isMine && !msg.deleted) ...[
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  setState(() {
                    _editing = msg;
                    _replyingTo = null;
                    _composer.text = msg.text;
                  });
                  _composerFocus.requestFocus();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _messages.deleteMessage(widget.peer, msg.id);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conv = _messages.conversations[widget.peer];
    final msgs = conv?.sortedMessages ?? const <ChatMessage>[];
    final isGroup = conv?.isGroup ?? false;
    final profile =
        isGroup ? null : ProfileService.instance.cached(widget.peer);
    final title = isGroup
        ? (conv?.displayName ?? 'Group')
        : (profile?.name.isNotEmpty ?? false)
            ? '${profile!.name} (${widget.peer})'
            : widget.peer;
    final subtitle = isGroup ? '${conv?.members.length ?? 0} members' : null;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            isGroup
                ? CircleAvatar(
                    radius: 16,
                    child: Icon(Icons.group,
                        size: 18,
                        color: Theme.of(context).colorScheme.onPrimary))
                : Avatar(atsign: widget.peer, profile: profile, radius: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, overflow: TextOverflow.ellipsis),
                  if (subtitle != null)
                    Text(subtitle,
                        style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
        actions: isGroup
            ? null
            : [
                IconButton(
                  tooltip: 'Voice call',
                  icon: const Icon(Icons.call_outlined),
                  onPressed: () =>
                      CallService.instance.startCall(widget.peer, video: false),
                ),
                IconButton(
                  tooltip: 'Video call',
                  icon: const Icon(Icons.videocam_outlined),
                  onPressed: () =>
                      CallService.instance.startCall(widget.peer, video: true),
                ),
              ],
      ),
      body: Column(
        children: [
          Expanded(
            child: msgs.isEmpty
                ? const Center(child: Text('Say hello 👋'))
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: msgs.length,
                    itemBuilder: (context, i) {
                      final msg = msgs[msgs.length - 1 - i];
                      final mine = msg.from == _me;
                      // In groups, label incoming messages with the sender.
                      final sender = (isGroup && !mine) ? msg.from : null;
                      if (msg.isCallEntry) {
                        return _CallEntry(msg: msg, isMine: mine);
                      }
                      if (msg.isAttachment) {
                        return _AttachmentBubble(
                          msg: msg,
                          isMine: mine,
                          status: _messages.statusOf(msg.id),
                          read: conv!.peerLastReadTs >= msg.ts,
                          sender: sender,
                          onLongPress: () => _showMessageActions(msg),
                        );
                      }
                      return _MessageBubble(
                        msg: msg,
                        isMine: mine,
                        conv: conv!,
                        status: _messages.statusOf(msg.id),
                        isFavorite: _messages.favorites.contains(msg.id),
                        sender: sender,
                        repliedTo: msg.replyTo == null
                            ? null
                            : conv.messagesById[msg.replyTo],
                        onLongPress: () => _showMessageActions(msg),
                      );
                    },
                  ),
          ),
          if (_replyingTo != null || _editing != null)
            _ComposerBanner(
              icon: _editing != null ? Icons.edit : Icons.reply,
              label: _editing != null
                  ? 'Editing message'
                  : 'Replying to: ${_replyingTo!.deleted ? "deleted message" : _replyingTo!.text}',
              onClose: () => setState(() {
                _replyingTo = null;
                if (_editing != null) _composer.clear();
                _editing = null;
              }),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _attachFile,
                    icon: const Icon(Icons.attach_file),
                    tooltip: 'Attach a file',
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      focusNode: _composerFocus,
                      decoration: const InputDecoration(
                        hintText: 'Message…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      minLines: 1,
                      maxLines: 5,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _send,
                    icon: Icon(_editing != null ? Icons.check : Icons.send),
                    tooltip: _editing != null ? 'Save edit' : 'Send',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Image preview or file chip, with tap-to-save.
class _AttachmentBubble extends StatelessWidget {
  final ChatMessage msg;
  final bool isMine;
  final DeliveryStatus status;
  final bool read;
  final String? sender;
  final VoidCallback onLongPress;

  const _AttachmentBubble({
    required this.msg,
    required this.isMine,
    required this.status,
    required this.read,
    required this.sender,
    required this.onLongPress,
  });

  Future<void> _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await MessageService.instance.loadAttachment(msg);
    if (bytes == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not load the file')));
      return;
    }
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save file',
      fileName: msg.fileName ?? 'file',
    );
    if (path == null) return;
    try {
      await File(path).writeAsBytes(bytes);
      messenger.showSnackBar(SnackBar(content: Text('Saved to $path')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubbleColor = isMine
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final sizeLabel =
        msg.fileSize == null ? '' : ' · ${MessageService.formatSize(msg.fileSize!)}';
    final timeLabel =
        DateFormat.Hm().format(DateTime.fromMillisecondsSinceEpoch(msg.ts));

    Widget content;
    if (msg.kind == 'image') {
      content = FutureBuilder(
        future: MessageService.instance.loadAttachment(msg),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              width: 200,
              height: 140,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final bytes = snapshot.data;
          if (bytes == null) {
            return const SizedBox(
              width: 200,
              height: 80,
              child: Center(child: Text('Image unavailable')),
            );
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(bytes,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Text('Broken image')),
          );
        },
      );
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined, size: 32),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(msg.fileName ?? 'file',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  '${msg.fileSize == null ? '' : MessageService.formatSize(msg.fileSize!)} · tap to save',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          (isMine && status == DeliveryStatus.sending)
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.download),
        ],
      );
    }

    // Uploading overlay on outgoing images (a WhatsApp-style spinner scrim).
    if (isMine && status == DeliveryStatus.sending && msg.kind == 'image') {
      content = Stack(
        alignment: Alignment.center,
        children: [
          content,
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
          ),
        ],
      );
    }

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: GestureDetector(
          onTap: () => _save(context),
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: EdgeInsets.all(msg.kind == 'image' ? 6 : 12),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (sender != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 2),
                    child: Text(sender!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        )),
                  ),
                content,
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 2, right: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$timeLabel$sizeLabel',
                          style: theme.textTheme.labelSmall),
                      if (isMine) ...[
                        const SizedBox(width: 6),
                        deliveryIndicator(context, status, read),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Centered call-history row, e.g. "📹 Video call · 2m 13s".
class _CallEntry extends StatelessWidget {
  final ChatMessage msg;
  final bool isMine;

  const _CallEntry({required this.msg, required this.isMine});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missed = msg.text.startsWith('Missed');
    final voice = msg.text.toLowerCase().contains('voice');
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              voice ? Icons.call : Icons.videocam,
              size: 16,
              color: missed
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              '${msg.text} · ${DateFormat.Hm().format(DateTime.fromMillisecondsSinceEpoch(msg.ts))}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: missed ? theme.colorScheme.error : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerBanner extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onClose;

  const _ComposerBanner(
      {required this.icon, required this.label, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  final bool isMine;
  final ConversationState conv;
  final DeliveryStatus status;
  final bool isFavorite;
  final ChatMessage? repliedTo;
  final String? sender;
  final VoidCallback onLongPress;

  const _MessageBubble({
    required this.msg,
    required this.isMine,
    required this.conv,
    required this.status,
    required this.isFavorite,
    required this.repliedTo,
    required this.sender,
    required this.onLongPress,
  });

  Widget _statusIcon(BuildContext context) {
    if (!isMine) return const SizedBox.shrink();
    return deliveryIndicator(context, status, conv.peerLastReadTs >= msg.ts);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reactions =
        conv.reactions[msg.id]?.values.toList() ?? const <Reaction>[];
    final bubbleColor = isMine
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onLongPress: onLongPress,
              onSecondaryTap: onLongPress,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (sender != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          sender!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    if (repliedTo != null)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface.withValues(alpha: .5),
                          borderRadius: BorderRadius.circular(8),
                          border: Border(
                            left: BorderSide(
                                color: theme.colorScheme.primary, width: 3),
                          ),
                        ),
                        child: Text(
                          repliedTo!.deleted
                              ? 'Message deleted'
                              : repliedTo!.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    Text(
                      msg.deleted ? 'Message deleted' : msg.text,
                      style: msg.deleted
                          ? theme.textTheme.bodyMedium
                              ?.copyWith(fontStyle: FontStyle.italic)
                          : theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isFavorite) ...[
                          const Icon(Icons.star, size: 12, color: Colors.amber),
                          const SizedBox(width: 4),
                        ],
                        if (msg.edited && !msg.deleted) ...[
                          Text('edited', style: theme.textTheme.labelSmall),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          DateFormat.Hm().format(
                              DateTime.fromMillisecondsSinceEpoch(msg.ts)),
                          style: theme.textTheme.labelSmall,
                        ),
                        const SizedBox(width: 4),
                        _statusIcon(context),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (reactions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Wrap(
                  spacing: 4,
                  children: [
                    for (final r in reactions)
                      Tooltip(
                        message: r.by,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: theme.colorScheme.outlineVariant),
                          ),
                          child: Text(r.emoji,
                              style: const TextStyle(fontSize: 13)),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
