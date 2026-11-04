import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeManager {
  /// Where the theme the user picked is stored.
  static const String themeModeKey = 'theme_mode';
  static final _themeModeNotifier = ValueNotifier<ThemeMode>(ThemeMode.system);

  static ValueNotifier<ThemeMode> get themeMode => _themeModeNotifier;

  static Future<void> saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(themeModeKey, mode.toString());
  }

  static void changeThemeMode(ThemeMode mode) {
    _themeModeNotifier.value = mode;
  }

  /// Synchronous initialization using an already-loaded SharedPreferences instance.
  /// Avoids redundant async SharedPreferences.getInstance() call during startup.
  static void initializeFromPrefs(SharedPreferences prefs) {
    final themeModeString = prefs.getString(themeModeKey);
    if (themeModeString == null) {
      _themeModeNotifier.value = ThemeMode.dark;
      return;
    }
    switch (themeModeString) {
      case 'ThemeMode.light':
        _themeModeNotifier.value = ThemeMode.light;
        break;
      case 'ThemeMode.dark':
        _themeModeNotifier.value = ThemeMode.dark;
        break;
      default:
        _themeModeNotifier.value = ThemeMode.system;
    }
  }
}
