import 'package:at_client_flutter/at_client_flutter.dart';
import 'package:at_utils/at_logger.dart';
import 'package:flutter/material.dart';

import 'core/constants.dart';
import 'core/navigation.dart';
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
    return MaterialApp(
      title: appTitle,
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const BootScreen(),
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
