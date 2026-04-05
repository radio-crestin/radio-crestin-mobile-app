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

    group('loadThemeMode', () {
      test('returns dark when nothing is stored', () async {
        final mode = await ThemeManager.loadThemeMode();
        expect(mode, ThemeMode.dark);
      });

      test('returns light when light is stored', () async {
        SharedPreferences.setMockInitialValues({
          'theme_mode': 'ThemeMode.light',
        });
        final mode = await ThemeManager.loadThemeMode();
        expect(mode, ThemeMode.light);
      });

      test('returns dark when dark is stored', () async {
        SharedPreferences.setMockInitialValues({
          'theme_mode': 'ThemeMode.dark',
        });
        final mode = await ThemeManager.loadThemeMode();
        expect(mode, ThemeMode.dark);
      });

      test('returns system for unknown stored value', () async {
        SharedPreferences.setMockInitialValues({
          'theme_mode': 'ThemeMode.unknown',
        });
        final mode = await ThemeManager.loadThemeMode();
        expect(mode, ThemeMode.system);
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

    group('initialize', () {
      test('loads saved theme and updates notifier', () async {
        SharedPreferences.setMockInitialValues({
          'theme_mode': 'ThemeMode.light',
        });

        await ThemeManager.initialize();
        expect(ThemeManager.themeMode.value, ThemeMode.light);
      });

      test('defaults to dark when nothing saved', () async {
        SharedPreferences.setMockInitialValues({});
        await ThemeManager.initialize();
        expect(ThemeManager.themeMode.value, ThemeMode.dark);
      });
    });
  });
}
