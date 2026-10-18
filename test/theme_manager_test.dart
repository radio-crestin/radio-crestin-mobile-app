import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/theme_manager.dart';

void main() {
  group('ThemeManager', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      // Reset notifier to default
      ThemeManager.changeThemeMode(ThemeMode.system);
    });

    group('saveThemeMode', () {
      test('saves light mode to SharedPreferences', () async {
        await ThemeManager.saveThemeMode(ThemeMode.light);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('theme_mode'), 'ThemeMode.light');
      });

      test('saves dark mode to SharedPreferences', () async {
        await ThemeManager.saveThemeMode(ThemeMode.dark);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('theme_mode'), 'ThemeMode.dark');
      });

      test('saves system mode to SharedPreferences', () async {
        await ThemeManager.saveThemeMode(ThemeMode.system);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('theme_mode'), 'ThemeMode.system');
      });
    });

    group('changeThemeMode', () {
      test('updates the ValueNotifier', () {
        ThemeManager.changeThemeMode(ThemeMode.light);
        expect(ThemeManager.themeMode.value, ThemeMode.light);
      });

      test('notifies listeners', () {
        final modes = <ThemeMode>[];
        ThemeManager.themeMode.addListener(() {
          modes.add(ThemeManager.themeMode.value);
        });

        ThemeManager.changeThemeMode(ThemeMode.light);
        ThemeManager.changeThemeMode(ThemeMode.dark);

        expect(modes, [ThemeMode.light, ThemeMode.dark]);
      });
    });

    group('initializeFromPrefs', () {
      Future<ThemeMode> initializedWith(Map<String, Object> saved) async {
        SharedPreferences.setMockInitialValues(saved);
        ThemeManager.initializeFromPrefs(await SharedPreferences.getInstance());
        return ThemeManager.themeMode.value;
      }

      test('defaults to dark when nothing is saved', () async {
        expect(await initializedWith({}), ThemeMode.dark);
      });

      test('loads the saved theme', () async {
        expect(await initializedWith({'theme_mode': 'ThemeMode.light'}),
            ThemeMode.light);
        expect(await initializedWith({'theme_mode': 'ThemeMode.dark'}),
            ThemeMode.dark);
        expect(await initializedWith({'theme_mode': 'ThemeMode.system'}),
            ThemeMode.system);
      });

      test('falls back to system for an unknown value', () async {
        expect(await initializedWith({'theme_mode': 'ThemeMode.unknown'}),
            ThemeMode.system);
      });
    });
  });
}
