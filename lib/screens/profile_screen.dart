import 'dart:convert';
import 'dart:typed_data';

import 'package:at_client/at_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/profile_service.dart';
import '../widgets/avatar.dart';
import 'crop_screen.dart';

/// Editor for our own lightweight public profile (name + short bio).
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _name = TextEditingController();
  final _bio = TextEditingController();
  String? _avatarB64;
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
      _avatarB64 = profile?.avatarB64;
      _loading = false;
    });
  }

  Future<void> _pickPhoto() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null || !mounted) return;
    try {
      // Let the user crop to a circle; the cropper returns a 256px PNG.
      final cropped = await Navigator.push<Uint8List>(
        context,
        MaterialPageRoute(builder: (_) => CropScreen(imageBytes: bytes)),
      );
      if (cropped == null) return;
      setState(() => _avatarB64 = base64Encode(cropped));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not load image: $e')));
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ProfileService.instance.saveMyProfile(
        Profile(
          name: _name.text.trim(),
          bio: _bio.text.trim(),
          avatarB64: _avatarB64,
        ),
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
                      Center(
                        child: Stack(
                          children: [
                            Avatar(
                              atsign: _me,
                              radius: 44,
                              profile: Profile(avatarB64: _avatarB64),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Material(
                                color: Theme.of(context).colorScheme.primary,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: _pickPhoto,
                                  child: Padding(
                                    padding: const EdgeInsets.all(6),
                                    child: Icon(Icons.camera_alt,
                                        size: 18,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimary),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_avatarB64 != null)
                        Center(
                          child: TextButton.icon(
                            onPressed: () => setState(() => _avatarB64 = null),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('Remove photo'),
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
