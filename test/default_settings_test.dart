import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/services/default_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings like the app's, each with its own notifier.
class _Settings {
  final theme = EnumDefaultSetting<ThemeMode>(
    id: 'themeMode',
    flagKey: 'default-theme-mode',
    prefsKey: 'theme_mode',
    builtInDefault: ThemeMode.dark,
    values: ThemeMode.values,
    live: ValueNotifier(ThemeMode.dark),
  );
  final seekMode = EnumDefaultSetting<SeekMode>(
    id: 'seekMode',
    flagKey: 'default-seek-mode',
    prefsKey: 'seek_mode',
    builtInDefault: SeekMode.twoMinutes,
    values: SeekMode.values,
    live: ValueNotifier(SeekMode.twoMinutes),
  );
  final unstable = BoolDefaultSetting(
    id: 'unstableConnection',
    flagKey: 'default-unstable-connection',
    prefsKey: 'unstable_connection',
    builtInDefault: false,
    live: ValueNotifier(false),
  );
  final autoStart = BoolDefaultSetting(
    id: 'autoStartStation',
    flagKey: 'default-auto-start-station',
    prefsKey: '_autoStartStation',
    builtInDefault: true,
  );

  List<DefaultSetting> get all => [theme, seekMode, unstable, autoStart];
}

void main() {
  late _Settings settings;

  setUp(() => settings = _Settings());

  Future<(DefaultSettings, SharedPreferences)> launch(
    Map<String, Object> stored, {
    Future<String?> Function(String flagKey)? readVariant,
  }) async {
    SharedPreferences.setMockInitialValues(stored);
    final prefs = await SharedPreferences.getInstance();
    final defaults = DefaultSettings(settings.all, readVariant: readVariant)
      ..initialize(prefs);
    return (defaults, prefs);
  }

  group('parseVariants', () {
    test('each variant names its value', () {
      expect(
        DefaultSettings.parseVariants({
          'themeMode': 'light',
          'seekMode': 'instant',
          'unstableConnection': 'on',
          'autoStartStation': 'off',
        }, settings.all),
        {
          'themeMode': ThemeMode.light,
          'seekMode': SeekMode.instant,
          'unstableConnection': true,
          'autoStartStation': false,
        },
      );
    });

    test('leaves out unknown variants and missing flags, one by one', () {
      final defaults = DefaultSettings.parseVariants({
        'themeMode': 'blue',
        'seekMode': 'fiveMinutes',
        'unstableConnection': 'true',
        'autoStartStation': null,
        'volume': 'loud',
      }, settings.all);

      expect(defaults, {'seekMode': SeekMode.fiveMinutes});
    });
  });

  group('effectiveValue', () {
    test("the user's value wins, then PostHog's, then the built-in one", () {
      expect(
        DefaultSettings.effectiveValue(
            userValue: 1, remoteDefault: 2, builtInDefault: 3),
        1,
      );
      expect(
        DefaultSettings.effectiveValue<int>(
            remoteDefault: 2, builtInDefault: 3),
        2,
      );
      expect(DefaultSettings.effectiveValue<int>(builtInDefault: 3), 3);
    });
  });

  group('isExistingChoice', () {
    test('a stored value other than the built-in default was picked', () {
      expect(
        DefaultSettings.isExistingChoice(
            stored: SeekMode.instant, builtInDefault: SeekMode.twoMinutes),
        isTrue,
      );
    });

    test('the built-in default, or nothing stored, is not a choice', () {
      expect(
        DefaultSettings.isExistingChoice(
            stored: SeekMode.twoMinutes, builtInDefault: SeekMode.twoMinutes),
        isFalse,
      );
      expect(
        DefaultSettings.isExistingChoice(stored: null, builtInDefault: true),
        isFalse,
      );
    });
  });

  group('at startup', () {
    test('a fresh install takes the built-in defaults', () async {
      final (_, prefs) = await launch({});

      expect(settings.theme.live!.value, ThemeMode.dark);
      expect(prefs.getString('theme_mode'), 'ThemeMode.dark');
      expect(prefs.getBool('_autoStartStation'), isTrue);
      for (final setting in settings.all) {
        expect(DefaultSettings.isUserSet(prefs, setting), isFalse);
      }
    });

    test('the cached variants apply before flags load', () async {
      final (_, prefs) = await launch({
        'default_setting_variant_themeMode': 'light',
        'default_setting_variant_autoStartStation': 'off',
      });

      expect(settings.theme.live!.value, ThemeMode.light);
      expect(prefs.getString('theme_mode'), 'ThemeMode.light');
      expect(prefs.getBool('_autoStartStation'), isFalse);
    });

    test('an existing install keeps the values the user picked', () async {
      final (_, prefs) = await launch({
        'theme_mode': 'ThemeMode.system',
        '_autoStartStation': false,
        'default_setting_variant_themeMode': 'light',
        'default_setting_variant_autoStartStation': 'on',
      });

      expect(DefaultSettings.isUserSet(prefs, settings.theme), isTrue);
      expect(DefaultSettings.isUserSet(prefs, settings.autoStart), isTrue);
      expect(prefs.getString('theme_mode'), 'ThemeMode.system');
      expect(prefs.getBool('_autoStartStation'), isFalse);
    });

    test('values the seek-mode migration wrote follow PostHog', () async {
      SharedPreferences.setMockInitialValues({
        'seek_mode': 'SeekMode.fiveMinutes',
        'unstable_connection': true,
        'default_setting_variant_seekMode': 'instant',
      });
      final prefs = await SharedPreferences.getInstance();
      SeekModeManager.initializeFromPrefs(prefs);

      DefaultSettings(settings.all).initialize(prefs);

      expect(DefaultSettings.isUserSet(prefs, settings.seekMode), isFalse);
      expect(DefaultSettings.isUserSet(prefs, settings.unstable), isFalse);
      expect(settings.seekMode.live!.value, SeekMode.instant);
      expect(prefs.getString('seek_mode'), 'SeekMode.instant');
    });

    test('a default PostHog stored is not taken for a choice later', () async {
      final (defaults, prefs) = await launch({});
      defaults.applyVariants({'themeMode': 'light'});

      // The next launch, after PostHog dropped the default.
      SharedPreferences.setMockInitialValues({
        for (final key in prefs.getKeys()) key: prefs.get(key)!,
      });
      final relaunched = await SharedPreferences.getInstance();
      DefaultSettings(settings.all)
        ..initialize(relaunched)
        ..applyVariants(const {});

      expect(DefaultSettings.isUserSet(relaunched, settings.theme), isFalse);
      expect(settings.theme.live!.value, ThemeMode.dark);
    });

    test('the old JSON payload cache is dropped', () async {
      final (_, prefs) = await launch({
        'mobile_default_settings_payload': '{"themeMode":"light"}',
      });

      expect(prefs.containsKey('mobile_default_settings_payload'), isFalse);
      expect(settings.theme.live!.value, ThemeMode.dark);
    });
  });

  group('when flags load', () {
    test('settings the user has not set follow the new defaults at once',
        () async {
      final (defaults, prefs) = await launch({});

      final changed = defaults.applyVariants({
        'themeMode': 'light',
        'seekMode': 'twoMinutes',
        'unstableConnection': 'on',
      });

      expect(changed, [settings.theme, settings.unstable]);
      expect(settings.theme.live!.value, ThemeMode.light);
      expect(settings.unstable.live!.value, isTrue);
      expect(prefs.getBool('unstable_connection'), isTrue);
    });

    test('a later change of the default is followed too', () async {
      final (defaults, _) = await launch({});
      defaults.applyVariants({'themeMode': 'light'});

      defaults.applyVariants({'themeMode': 'system'});

      expect(settings.theme.live!.value, ThemeMode.system);
    });

    test('a flag turned off brings back the built-in default', () async {
      final (defaults, prefs) = await launch({});
      defaults.applyVariants({'autoStartStation': 'off'});

      final changed = defaults.applyVariants({'autoStartStation': null});

      expect(changed, [settings.autoStart]);
      expect(prefs.getBool('_autoStartStation'), isTrue);
    });

    test("the user's choice wins for good once they made it", () async {
      final (defaults, prefs) = await launch({});
      defaults.applyVariants({'seekMode': 'instant'});

      // The user picks 5 minutes in Settings.
      settings.seekMode.live!.value = SeekMode.fiveMinutes;
      await prefs.setString('seek_mode', 'SeekMode.fiveMinutes');
      await DefaultSettings.markUserSet(settings.seekMode);
      final changed = defaults.applyVariants({'seekMode': 'twoMinutes'});

      expect(changed, isEmpty);
      expect(settings.seekMode.live!.value, SeekMode.fiveMinutes);
      expect(prefs.getString('seek_mode'), 'SeekMode.fiveMinutes');
    });

    test('each variant is cached for the next launch', () async {
      final (defaults, prefs) = await launch({});

      defaults.applyVariants({'themeMode': 'light'});

      expect(prefs.getString('default_setting_variant_themeMode'), 'light');
      defaults.applyVariants({'themeMode': null});
      expect(prefs.containsKey('default_setting_variant_themeMode'), isFalse);
    });

    test('reads each setting from its own flag', () async {
      final flags = {
        'default-theme-mode': 'light',
        'default-auto-start-station': 'off',
      };
      final (defaults, _) =
          await launch({}, readVariant: (key) async => flags[key]);

      final changed = await defaults.onFlagsLoaded();

      expect(changed, [settings.theme, settings.autoStart]);
      expect(settings.theme.live!.value, ThemeMode.light);
    });

    test('a flag that fails to read keeps its cached variant', () async {
      final (defaults, _) = await launch(
        {'default_setting_variant_themeMode': 'light'},
        readVariant: (key) async =>
            key == 'default-theme-mode' ? throw StateError('offline') : null,
      );

      await defaults.onFlagsLoaded();

      expect(settings.theme.live!.value, ThemeMode.light);
    });
  });

  group('AppDefaultSettings', () {
    test("built-in defaults are today's", () {
      expect({
        for (final setting in AppDefaultSettings.all)
          setting.id: setting.builtInDefault,
      }, {
        'themeMode': ThemeMode.dark,
        'seekMode': SeekMode.twoMinutes,
        'unstableConnection': false,
        'autoStartStation': true,
        'notificationsEnabled': true,
        'preferDirectStreams': false,
      });
    });

    test('each setting has its own flag', () {
      expect([for (final setting in AppDefaultSettings.all) setting.flagKey], [
        'default-theme-mode',
        'default-seek-mode',
        'default-unstable-connection',
        'default-auto-start-station',
        'default-notifications-enabled',
        'default-prefer-direct-streams',
      ]);
    });

    test('the variants of the built-in defaults parse to them', () {
      expect(
        DefaultSettings.parseVariants({
          'themeMode': 'dark',
          'seekMode': 'twoMinutes',
          'unstableConnection': 'off',
          'autoStartStation': 'on',
          'notificationsEnabled': 'on',
          'preferDirectStreams': 'off',
        }, AppDefaultSettings.all),
        {
          for (final setting in AppDefaultSettings.all)
            setting.id: setting.builtInDefault,
        },
      );
    });
  });
}
