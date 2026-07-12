import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';
import 'welcome_screen.dart';

/// Mandatory First-Run Atsign Gate.
///
/// Shown as a full-screen blocking page whenever no Atsign is configured on
/// this device (KeychainStorage().getAllAtsigns() is empty). The user cannot
/// reach any authentication workflow until they pass through this screen.
class AtsignGateScreen extends StatelessWidget {
  const AtsignGateScreen({super.key});

  Future<void> _openStarterPack(BuildContext context) async {
    final uri = Uri.parse(starterPackUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open browser. Visit $starterPackUrl')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.alternate_email,
                    size: 64, color: theme.colorScheme.primary),
                const SizedBox(height: 24),
                Text(
                  'Using this app requires an Atsign.',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Text(
                  'If you already have an Atsign, click "Continue."',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                Text(
                  'Or, get free, temporary Atsigns via the Starter Pack:',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  '1. Click "Get My Starter Pack" below or visit '
                  '$starterPackUrl in your browser.\n'
                  '2. Enter your email address.\n'
                  '3. Verify your email with a one-time passcode.\n'
                  '4. Come back to the app and click "Continue."',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: () => _openStarterPack(context),
                  icon: const Icon(Icons.card_giftcard),
                  label: const Text('Get My Starter Pack'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const WelcomeScreen()),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
