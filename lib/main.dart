import 'package:at_client_flutter/at_client_flutter.dart';
import 'package:at_utils/at_logger.dart';
import 'package:flutter/material.dart';

import 'core/constants.dart';
import 'core/navigation.dart';
import 'core/theme.dart';
import 'screens/atsign_gate_screen.dart';
import 'screens/welcome_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AtSignLogger.root_level = 'warning';
  runApp(const SecureMessagingApp());
}

class SecureMessagingApp extends StatelessWidget {
  const SecureMessagingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) => MaterialApp(
        title: appTitle,
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        // `theme` holds the user's selected theme (which may be dark); pin
        // themeMode to light so MaterialApp always renders `theme` regardless
        // of the OS setting. The auth flow re-forces light locally for the
        // packaged Atsign dialogs (see WelcomeScreen).
        theme: ThemeController.instance.data,
        themeMode: ThemeMode.light,
        home: const BootScreen(),
      ),
    );
  }
}

/// Decides the first screen: the mandatory First-Run Atsign Gate when no
/// Atsign exists on this device, otherwise the Welcome/Auth screen.
class BootScreen extends StatelessWidget {
  const BootScreen({super.key});

  Future<bool> _hasAtsigns() async {
    try {
      final atSigns = await KeychainStorage().getAllAtsigns();
      return atSigns.isNotEmpty;
    } catch (_) {
      // If the keychain is unreadable, be safe and show the gate.
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _hasAtsigns(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return snapshot.data!
            ? const WelcomeScreen()
            : const AtsignGateScreen();
      },
    );
  }
}
