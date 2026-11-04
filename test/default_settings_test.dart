import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/services/default_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings like the app's, each with its own notifier.
class _Settings {
  final theme = EnumDefaultSetting<ThemeMode>(
    payloadKey: 'themeMode',
    prefsKey: 'theme_mode',
    builtInDefault: ThemeMode.dark,
    values: ThemeMode.values,
    live: ValueNotifier(ThemeMode.dark),
  );
  final seekMode = EnumDefaultSetting<SeekMode>(
    payloadKey: 'seekMode',
    prefsKey: 'seek_mode',
    builtInDefault: SeekMode.twoMinutes,
    values: SeekMode.values,
    live: ValueNotifier(SeekMode.twoMinutes),
  );
  final unstable = BoolDefaultSetting(
    payloadKey: 'unstableConnection',
    prefsKey: 'unstable_connection',
    builtInDefault: false,
    live: ValueNotifier(false),
  );
  final autoStart = BoolDefaultSetting(
    payloadKey: 'autoStartStation',
    prefsKey: '_autoStartStation',
    builtInDefault: true,
  );

  List<DefaultSetting> get all => [theme, seekMode, unstable, autoStart];
}

void main() {
  late _Settings settings;

  setUp(() => settings = _Settings());

  Future<(DefaultSettings, SharedPreferences)> launch(
      Map<String, Object> stored) async {
    SharedPreferences.setMockInitialValues(stored);
    final prefs = await SharedPreferences.getInstance();
    return (DefaultSettings(settings.all)..initialize(prefs), prefs);
  }

  group('parsePayload', () {
    test('reads every valid default, from a map or its JSON text', () {
      const json = '{"themeMode":"light","seekMode":"instant",'
          '"unstableConnection":true,"autoStartStation":false}';
      final expected = {
        'themeMode': ThemeMode.light,
        'seekMode': SeekMode.instant,
        'unstableConnection': true,
        'autoStartStation': false,
      };

      expect(DefaultSettings.parsePayload(json, settings.all), expected);
      expect(
        DefaultSettings.parsePayload({
          'themeMode': 'light',
          'seekMode': 'instant',
          'unstableConnection': true,
          'autoStartStation': false,
        }, settings.all),
        expected,
      );
    });

    test('reads JSON text that was encoded twice', () {
      expect(
        DefaultSettings.parsePayload(
            r'"{\"themeMode\":\"system\"}"', settings.all),
        {'themeMode': ThemeMode.system},
      );
    });

    test('leaves out invalid values and unknown keys, one by one', () {
      final defaults = DefaultSettings.parsePayload({
        'themeMode': 'blue',
        'seekMode': 'fiveMinutes',
        'unstableConnection': 'yes',
        'autoStartStation': 1,
        'volume': 11,
      }, settings.all);

      expect(defaults, {'seekMode': SeekMode.fiveMinutes});
    });

    test('a missing flag or invalid JSON gives no defaults', () {
      for (final payload in [null, '', '{not json', '[1, 2]', 42]) {
        expect(DefaultSettings.parsePayload(payload, settings.all), isEmpty,
            reason: '$payload');
      }
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

    test('the cached payload applies before flags load', () async {
      final (_, prefs) = await launch({
        'mobile_default_settings_payload':
            '{"themeMode":"light","autoStartStation":false}',
      });

      expect(settings.theme.live!.value, ThemeMode.light);
      expect(prefs.getString('theme_mode'), 'ThemeMode.light');
      expect(prefs.getBool('_autoStartStation'), isFalse);
    });

    test('an existing install keeps the values the user picked', () async {
      final (_, prefs) = await launch({
        'theme_mode': 'ThemeMode.system',
        '_autoStartStation': false,
        'mobile_default_settings_payload':
            '{"themeMode":"light","autoStartStation":true}',
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
        'mobile_default_settings_payload': '{"seekMode":"instant"}',
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
      defaults.applyPayload({'themeMode': 'light'});

      // The next launch, after PostHog dropped the default.
      SharedPreferences.setMockInitialValues({
        for (final key in prefs.getKeys()) key: prefs.get(key)!,
      });
      final relaunched = await SharedPreferences.getInstance();
      DefaultSettings(settings.all)
        ..initialize(relaunched)
        ..applyPayload(null);

      expect(DefaultSettings.isUserSet(relaunched, settings.theme), isFalse);
      expect(settings.theme.live!.value, ThemeMode.dark);
    });
  });

  group('when flags load', () {
    test('settings the user has not set follow the new defaults at once',
        () async {
      final (defaults, prefs) = await launch({});

      final changed = defaults.applyPayload({
        'themeMode': 'light',
        'seekMode': 'twoMinutes',
        'unstableConnection': true,
      });

      expect(changed, [settings.theme, settings.unstable]);
      expect(settings.theme.live!.value, ThemeMode.light);
      expect(settings.unstable.live!.value, isTrue);
      expect(prefs.getBool('unstable_connection'), isTrue);
    });

    test('a later change of the default is followed too', () async {
      final (defaults, _) = await launch({});
      defaults.applyPayload({'themeMode': 'light'});

      defaults.applyPayload({'themeMode': 'system'});

      expect(settings.theme.live!.value, ThemeMode.system);
    });

    test('a removed flag brings back the built-in defaults', () async {
      final (defaults, prefs) = await launch({});
      defaults.applyPayload({'autoStartStation': false});

      final changed = defaults.applyPayload(null);

      expect(changed, [settings.autoStart]);
      expect(prefs.getBool('_autoStartStation'), isTrue);
    });

    test("the user's choice wins for good once they made it", () async {
      final (defaults, prefs) = await launch({});
      defaults.applyPayload({'seekMode': 'instant'});

      // The user picks 5 minutes in Settings.
      settings.seekMode.live!.value = SeekMode.fiveMinutes;
      await prefs.setString('seek_mode', 'SeekMode.fiveMinutes');
      await DefaultSettings.markUserSet(settings.seekMode);
      final changed = defaults.applyPayload({'seekMode': 'twoMinutes'});

      expect(changed, isEmpty);
      expect(settings.seekMode.live!.value, SeekMode.fiveMinutes);
      expect(prefs.getString('seek_mode'), 'SeekMode.fiveMinutes');
    });

    test('the payload is cached for the next launch', () async {
      final (defaults, prefs) = await launch({});

      defaults.applyPayload({'themeMode': 'light'});

      expect(prefs.getString('mobile_default_settings_payload'),
          '{"themeMode":"light"}');
      defaults.applyPayload(null);
      expect(prefs.getString('mobile_default_settings_payload'), isNull);
    });
  });

  group('AppDefaultSettings', () {
    test("built-in defaults are today's", () {
      final builtIn = {
        for (final setting in AppDefaultSettings.all)
          setting.payloadKey: setting.builtInDefault,
      };

      expect(builtIn, {
        'themeMode': ThemeMode.dark,
        'seekMode': SeekMode.twoMinutes,
        'unstableConnection': false,
        'autoStartStation': true,
        'notificationsEnabled': true,
        'preferDirectStreams': false,
      });
    });

    test('a payload of the built-in defaults parses to them', () {
      const payload = '{"themeMode":"dark","seekMode":"twoMinutes",'
          '"unstableConnection":false,"autoStartStation":true,'
          '"notificationsEnabled":true,"preferDirectStreams":false}';

      expect(
        DefaultSettings.parsePayload(payload, AppDefaultSettings.all),
        {
          for (final setting in AppDefaultSettings.all)
            setting.payloadKey: setting.builtInDefault,
        },
      );
    });
  });
}
