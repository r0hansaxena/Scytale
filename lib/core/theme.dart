import 'package:at_client/at_client.dart';
import 'package:flutter/material.dart';

import 'constants.dart';

/// A selectable app theme.
class AppThemeOption {
  final String name;
  final IconData icon;
  final ThemeData data;
  const AppThemeOption(this.name, this.icon, this.data);
}

ThemeData _theme(Color seed, Brightness brightness) => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
      useMaterial3: true,
    );

/// The available themes. Index 0 (Light) is the default and the one the
/// light-only Atsign onboarding dialogs render under.
final List<AppThemeOption> appThemes = [
  AppThemeOption('Light', Icons.light_mode, _theme(Colors.teal, Brightness.light)),
  AppThemeOption('Dark', Icons.dark_mode, _theme(Colors.teal, Brightness.dark)),
  AppThemeOption('Ocean', Icons.water_drop, _theme(Colors.indigo, Brightness.dark)),
  AppThemeOption('Sunset', Icons.wb_twilight, _theme(Colors.deepOrange, Brightness.light)),
];

/// Holds the selected theme and persists it as a self AtKey (`theme.scytale`)
/// so the choice follows the user across devices.
class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  int _index = 0;
  int get index => _index;
  AppThemeOption get option => appThemes[_index];
  ThemeData get data => option.data;

  /// The always-light theme used for the onboarding/auth flow.
  ThemeData get authTheme => appThemes[0].data;

  AtKey _key(String me) => AtKey()
    ..key = 'theme'
    ..namespace = appNamespace
    ..sharedBy = me;

  Future<void> setIndex(int i) async {
    if (i < 0 || i >= appThemes.length || i == _index) return;
    _index = i;
    notifyListeners();
    await _save();
  }

  /// Load the saved theme after login.
  Future<void> load() async {
    try {
      final atClient = AtClientManager.getInstance().atClient;
      final me = atClient.getCurrentAtSign();
      if (me == null) return;
      final value = (await atClient.get(_key(me))).value as String?;
      final idx = appThemes.indexWhere((o) => o.name == value);
      if (idx >= 0) {
        if (idx != _index) {
          _index = idx;
          notifyListeners();
        }
      } else {
        // No saved theme yet — persist the current (possibly pre-login) choice.
        await _save();
      }
    } catch (_) {
      // Non-critical; keep the default theme.
    }
  }

  Future<void> _save() async {
    try {
      final atClient = AtClientManager.getInstance().atClient;
      final me = atClient.getCurrentAtSign();
      if (me == null) return;
      await atClient.put(_key(me), option.name);
    } catch (_) {}
  }

  /// Reset to the default on logout.
  void reset() {
    if (_index == 0) return;
    _index = 0;
    notifyListeners();
  }
}

/// Bottom-sheet theme chooser, usable from any screen (gate, welcome, inbox).
void showThemePicker(BuildContext context) {
  showModalBottomSheet(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListenableBuilder(
        listenable: ThemeController.instance,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Theme',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            for (var i = 0; i < appThemes.length; i++)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: appThemes[i].data.colorScheme.primary,
                  child: Icon(appThemes[i].icon,
                      color: appThemes[i].data.colorScheme.onPrimary, size: 20),
                ),
                title: Text(appThemes[i].name),
                trailing: ThemeController.instance.index == i
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => ThemeController.instance.setIndex(i),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}
