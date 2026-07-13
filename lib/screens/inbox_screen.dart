import 'package:at_client/at_client.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../models/models.dart';
import '../services/message_service.dart';
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
          decoration: const InputDecoration(
            labelText: 'Atsign',
            hintText: '@alice',
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
          final convs = _messages.conversations.values.toList()
            ..sort((a, b) =>
                (b.lastMessage?.ts ?? 0).compareTo(a.lastMessage?.ts ?? 0));
          if (convs.isEmpty) {
            return const Center(
              child: Text('No conversations yet.\nStart one with the + button.',
                  textAlign: TextAlign.center),
            );
          }
          return ListView.builder(
            itemCount: convs.length,
            itemBuilder: (context, i) {
              final conv = convs[i];
              final last = conv.lastMessage;
              final unread = conv.unreadCount(_me);
              final profile = _profiles.cached(conv.peer);
              final title = (profile?.name.isNotEmpty ?? false)
                  ? '${profile!.name} (${conv.peer})'
                  : conv.peer;
              return ListTile(
                leading: CircleAvatar(
                  child: Text(conv.peer.length > 1
                      ? conv.peer[1].toUpperCase()
                      : '@'),
                ),
                title: Text(title, overflow: TextOverflow.ellipsis),
                subtitle: last == null
                    ? const Text('No messages yet')
                    : Text(
                        _previewText(last),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: unread > 0
                    ? Badge.count(count: unread)
                    : null,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) =>
                          ConversationScreen(peer: conv.peer)),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _newChat,
        tooltip: 'New chat',
        child: const Icon(Icons.add_comment),
      ),
    );
  }
}
