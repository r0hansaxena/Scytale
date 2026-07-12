import 'dart:async';

import 'package:flutter/material.dart';

import '../services/agent_client.dart';
import '../services/message_service.dart';

/// UI for the Personal AI Agent: "what did I miss?", conversation summaries,
/// and action-item extraction, invoked over AtRpc to the agent process
/// running under our own Atsign.
class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key});

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  bool _busy = false;
  String? _result;
  String? _mode; // 'claude' or 'heuristic', reported by the agent
  String? _error;
  String? _selectedPeer;

  Future<void> _run(
      Future<Map<String, dynamic>> Function() request, String label) async {
    setState(() {
      _busy = true;
      _result = null;
      _error = null;
      _mode = null;
    });
    try {
      final response = await request();
      setState(() {
        _result = response['result']?.toString() ?? response.toString();
        _mode = response['mode']?.toString();
      });
    } on TimeoutException {
      setState(() {
        _error = 'The agent did not respond.\n\n'
            'Make sure the Personal AI Agent process is running:\n'
            'dart run bin/personal_agent.dart -a <your Atsign> '
            '(from the agent/ directory)';
      });
    } catch (e) {
      setState(() => _error = '$label failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peers = MessageService.instance.conversations.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('Personal AI Agent')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Your agent runs under your own Atsign in an isolated '
                  'namespace. It only reads your data — no cross-user '
                  'inference, no shared memory.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String?>(
                  initialValue: _selectedPeer,
                  decoration: const InputDecoration(
                    labelText: 'Conversation (optional — default: all)',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('All conversations')),
                    for (final p in peers)
                      DropdownMenuItem<String?>(value: p, child: Text(p)),
                  ],
                  onChanged: (v) => setState(() => _selectedPeer = v),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.update),
                      label: const Text('What did I miss?'),
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => AgentClient.instance.whatDidIMiss(),
                              'What did I miss'),
                    ),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.summarize_outlined),
                      label: const Text('Summarize'),
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => AgentClient.instance
                                  .summarize(peer: _selectedPeer),
                              'Summarize'),
                    ),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.checklist),
                      label: const Text('Action items'),
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => AgentClient.instance
                                  .actionItems(peer: _selectedPeer),
                              'Action items'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (_busy)
                  const Center(child: CircularProgressIndicator())
                else if (_error != null)
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!,
                          style: TextStyle(
                              color: theme.colorScheme.onErrorContainer)),
                    ),
                  )
                else if (_result != null)
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_mode != null)
                              Chip(
                                label: Text(_mode == 'claude'
                                    ? 'Claude AI'
                                    : 'Heuristic digest'),
                                visualDensity: VisualDensity.compact,
                              ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: SingleChildScrollView(
                                child: SelectableText(_result!),
                              ),
                            ),
                          ],
                        ),
                      ),
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
