import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../services/auth_service.dart';

/// Welcome / Auth screen offering all four authentication workflows.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.lock_outline,
                    size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  appTitle,
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'End-to-end encrypted messaging on the Atsign Platform.\n'
                  'No servers. No accounts. Your keys, your data.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                _AuthButton(
                  icon: Icons.key,
                  title: 'Login from Keychain',
                  subtitle: 'Use an Atsign already on this device',
                  onPressed: () => loginWithKeychain(context),
                ),
                _AuthButton(
                  icon: Icons.person_add_alt,
                  title: 'Onboard a New Atsign',
                  subtitle: 'Activate an Atsign for the first time',
                  onPressed: () => onboard(context),
                ),
                _AuthButton(
                  icon: Icons.devices,
                  title: 'Enroll This Device (APKAM)',
                  subtitle: 'Approve from another device you own',
                  onPressed: () => loginWithApkam(context),
                ),
                _AuthButton(
                  icon: Icons.upload_file,
                  title: 'Login with .atKeys File',
                  subtitle: 'Import your backed-up keys file',
                  onPressed: () => loginWithFile(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;

  const _AuthButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onPressed,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      ),
    );
  }
}
