import 'package:at_client/at_client.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/profile_service.dart';

/// Editor for our own lightweight public profile (name + short bio).
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _name = TextEditingController();
  final _bio = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  String get _me =>
      AtClientManager.getInstance().atClient.getCurrentAtSign() ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await ProfileService.instance.fetch(_me, refresh: true);
    if (!mounted) return;
    setState(() {
      _name.text = profile?.name ?? '';
      _bio.text = profile?.bio ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ProfileService.instance.saveMyProfile(
        Profile(name: _name.text.trim(), bio: _bio.text.trim()),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile published')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save profile: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CircleAvatar(
                        radius: 36,
                        child: Text(
                          _me.length > 1 ? _me[1].toUpperCase() : '@',
                          style: const TextStyle(fontSize: 28),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(_me,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'Display name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _bio,
                        maxLines: 3,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          labelText: 'Short bio',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Your profile is published as a public AtKey so '
                        'people you chat with can see who you are.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Publish profile'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
