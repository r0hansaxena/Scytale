import 'package:at_client/at_client.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../services/message_service.dart';
import '../widgets/avatar.dart';
import '../services/profile_service.dart';
import 'agent_screen.dart';
import 'conversation_screen.dart';
import 'profile_screen.dart';
import 'welcome_screen.dart';
import '../services/auth_service.dart' as auth;

/// Conversation list with unread counts; entry point to chats, the profile
/// editor, and the Personal AI Agent.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  final MessageService _messages = MessageService.instance;
  final ProfileService _profiles = ProfileService.instance;

  bool _showArchived = false;

  String get _me =>
      AtClientManager.getInstance().atClient.getCurrentAtSign() ?? '';

  @override
  void initState() {
    super.initState();
    // Warm the profile cache for known peers.
    for (final peer in _messages.conversations.keys) {
      _profiles.fetch(peer);
    }
  }

  /// Right-click / long-press menu for a conversation.
  Future<void> _showConvMenu(String peer, bool unread, Offset? pos) async {
    final archived = _messages.isArchived(peer);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final at = pos ?? overlay.size.center(Offset.zero);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: unread ? 'read' : 'unread',
          child: Text(unread ? 'Mark as read' : 'Mark as unread'),
        ),
        PopupMenuItem(
          value: 'archive',
          child: Text(archived ? 'Unarchive' : 'Archive'),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Text('Delete chat', style: TextStyle(color: Colors.red)),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'read':
        _messages.markRead(peer);
      case 'unread':
        _messages.markUnread(peer);
      case 'archive':
        _messages.toggleArchive(peer);
      case 'delete':
        _confirmDelete(peer);
    }
  }

  Future<void> _confirmDelete(String peer) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
            'This removes your copy of the conversation with $peer from all '
            'your devices. The other person keeps their copy.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) _messages.deleteConversation(peer);
  }

  String _previewText(ChatMessage m) {
    if (m.deleted) return 'Message deleted';
    if (m.kind == 'image') return '📷 Photo';
    if (m.kind == 'file') return '📎 ${m.fileName ?? 'File'}';
    if (m.kind == 'call') return '📹 ${m.text}';
    return m.text;
  }

  Future<void> _newChat() async {
    final controller = TextEditingController();
    final peer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          // Show a fixed "@" prefix and strip any "@" the user types so the
          // field never doubles up.
          onChanged: (v) {
            if (v.startsWith('@')) {
              controller.value = TextEditingValue(
                text: v.substring(1),
                selection:
                    TextSelection.collapsed(offset: controller.selection.end - 1),
              );
            }
          },
          decoration: const InputDecoration(
            labelText: 'Atsign',
            prefixText: '@',
            hintText: 'alice',
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Start'),
          ),
        ],
      ),
    );
    if (peer == null || peer.trim().isEmpty || !mounted) return;

    try {
      final atsign = peer.trim().toAtsign();
      _messages.openConversation(atsign);
      _profiles.fetch(atsign);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => ConversationScreen(peer: atsign)),
      );
    } on InvalidAtSignException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid Atsign: ${e.message}')),
      );
    }
  }

  void _newMenu() {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_add_alt),
              title: const Text('New chat'),
              onTap: () {
                Navigator.pop(sheetContext);
                _newChat();
              },
            ),
            ListTile(
              leading: const Icon(Icons.group_add),
              title: const Text('New group'),
              onTap: () {
                Navigator.pop(sheetContext);
                _newGroup();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _newGroup() async {
    final nameCtrl = TextEditingController();
    final membersCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Group name',
                hintText: 'Team',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: membersCtrl,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Members',
                hintText: '@alice @bob  (space or comma separated)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final raw = membersCtrl.text.split(RegExp(r'[\s,]+'));
    final members = <String>[];
    try {
      for (final m in raw) {
        if (m.trim().isEmpty) continue;
        members.add(m.trim().toAtsign());
      }
    } on InvalidAtSignException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid Atsign: ${e.message}')),
      );
      return;
    }
    if (members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one member')),
      );
      return;
    }
    final groupId = await _messages.createGroup(nameCtrl.text, members);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ConversationScreen(peer: groupId)),
    );
  }

  Future<void> _logout() async {
    await auth.logout(context);
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const WelcomeScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(appTitle, style: TextStyle(fontSize: 16)),
            Text(_me,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _showArchived ? 'Show inbox' : 'Show archived',
            icon: Icon(_showArchived
                ? Icons.inbox_outlined
                : Icons.archive_outlined),
            onPressed: () => setState(() => _showArchived = !_showArchived),
          ),
          IconButton(
            tooltip: 'Personal AI Agent',
            icon: const Icon(Icons.smart_toy_outlined),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (context) => const AgentScreen())),
          ),
          IconButton(
            tooltip: 'My profile',
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (context) => const ProfileScreen())),
          ),
          IconButton(
            tooltip: 'Theme',
            icon: const Icon(Icons.palette_outlined),
            onPressed: () => showThemePicker(context),
          ),
          IconButton(
            tooltip: 'Export .atKeys (backup / agent login)',
            icon: const Icon(Icons.key_outlined),
            onPressed: () => auth.exportKeys(context),
          ),
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_messages, _profiles]),
        builder: (context, _) {
          final convs = _messages.conversations.values
              .where((c) =>
                  _messages.archived.contains(c.peer) == _showArchived)
              .toList()
            ..sort((a, b) =>
                (b.lastMessage?.ts ?? 0).compareTo(a.lastMessage?.ts ?? 0));
          if (convs.isEmpty) {
            return Center(
              child: Text(
                  _showArchived
                      ? 'No archived chats.'
                      : 'No conversations yet.\nStart one with the + button.',
                  textAlign: TextAlign.center),
            );
          }
          return ListView.builder(
            itemCount: convs.length,
            itemBuilder: (context, i) {
              final conv = convs[i];
              final last = conv.lastMessage;
              final unread = conv.unreadCount(_me);
              if (!conv.isGroup) {
                _profiles.ensure(conv.peer); // pull the peer's profile
              }
              final profile =
                  conv.isGroup ? null : _profiles.cached(conv.peer);
              final title = conv.isGroup
                  ? conv.displayName
                  : (profile?.name.isNotEmpty ?? false)
                      ? '${profile!.name} (${conv.peer})'
                      : conv.peer;
              return GestureDetector(
                onSecondaryTapUp: (d) =>
                    _showConvMenu(conv.peer, unread > 0, d.globalPosition),
                child: ListTile(
                  leading: conv.isGroup
                      ? CircleAvatar(
                          child: Icon(Icons.group,
                              color: Theme.of(context).colorScheme.onPrimary),
                        )
                      : Avatar(atsign: conv.peer, profile: profile),
                  title: Text(title, overflow: TextOverflow.ellipsis),
                  subtitle: last == null
                      ? const Text('No messages yet')
                      : Text(
                          _previewText(last),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: unread > 0 ? Badge.count(count: unread) : null,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) =>
                            ConversationScreen(peer: conv.peer)),
                  ),
                  onLongPress: () => _showConvMenu(conv.peer, unread > 0, null),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _newMenu,
        tooltip: 'New chat or group',
        child: const Icon(Icons.add_comment),
      ),
    );
  }
}
