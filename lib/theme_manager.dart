import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeManager {
  static const String _themeModeKey = 'theme_mode';
  static final _themeModeNotifier = ValueNotifier<ThemeMode>(ThemeMode.system);

  static ValueNotifier<ThemeMode> get themeMode => _themeModeNotifier;

  static Future<void> saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, mode.toString());
  }

  static Future<ThemeMode> loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final themeModeString = prefs.getString(_themeModeKey);
    
    if (themeModeString == null) {
      return ThemeMode.dark;
    }

    switch (themeModeString) {
      case 'ThemeMode.light':
        return ThemeMode.light;
      case 'ThemeMode.dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static void changeThemeMode(ThemeMode mode) {
    _themeModeNotifier.value = mode;
  }

  static Future<void> initialize() async {
    final savedMode = await loadThemeMode();
    _themeModeNotifier.value = savedMode;
  }

  /// Synchronous initialization using an already-loaded SharedPreferences instance.
  /// Avoids redundant async SharedPreferences.getInstance() call during startup.
  static void initializeFromPrefs(SharedPreferences prefs) {
    final themeModeString = prefs.getString(_themeModeKey);
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
