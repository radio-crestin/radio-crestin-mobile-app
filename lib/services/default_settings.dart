import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart' show ThemeMode, ValueNotifier;
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../seek_mode_manager.dart';
import '../theme_manager.dart';
import 'playback_preferences.dart';

/// A setting whose default comes from PostHog until the user changes it.
///
/// Its value stays stored under [prefsKey], where the code that reads the
/// setting finds it: while the user has not changed it, that is the
/// default in force, rewritten whenever the default changes.
abstract class DefaultSetting<T extends Object> {
  DefaultSetting({
    required this.payloadKey,
    required this.prefsKey,
    required this.builtInDefault,
    this.live,
  });

  /// Its key in the `mobile-default-settings` flag payload.
  final String payloadKey;

  /// Where its value is stored.
  final String prefsKey;

  /// The default when PostHog gives none: the app's own.
  final T builtInDefault;

  /// The notifier the app follows the setting with, if it follows it live.
  final ValueNotifier<T>? live;

  /// Where "the user changed it in Settings" is stored.
  String get userSetKey => 'setting_user_set_$payloadKey';

  /// [json] as a value of this setting, or null when it is not one.
  T? fromPayload(Object? json);

  /// The stored value, or null when none or not a value of this setting.
  T? readStored(SharedPreferences prefs);

  /// Stores [value].
  Future<void> writeStored(SharedPreferences prefs, T value);

  /// The value this setting takes when the user has [userSet] it or not,
  /// given its [stored] value and the [remoteDefaults] in force.
  T valueFor({
    required bool userSet,
    T? stored,
    required Map<String, Object> remoteDefaults,
  }) {
    final remote = remoteDefaults[payloadKey];
    return DefaultSettings.effectiveValue(
      userValue: userSet ? stored : null,
      remoteDefault: remote is T ? remote : null,
      builtInDefault: builtInDefault,
    );
  }

  /// Makes the stored value and [live] follow the [remoteDefaults], unless
  /// the user set this setting. Returns whether the value changed.
  bool follow(SharedPreferences prefs, Map<String, Object> remoteDefaults) {
    if (DefaultSettings.isUserSet(prefs, this)) return false;
    final value = valueFor(userSet: false, remoteDefaults: remoteDefaults);
    final storedChanged = readStored(prefs) != value;
    if (storedChanged) unawaited(writeStored(prefs, value));
    final notifier = live;
    final liveChanged = notifier != null && notifier.value != value;
    if (liveChanged) notifier.value = value;
    return storedChanged || liveChanged;
  }
}

/// An on/off setting, `true` or `false` in the payload.
class BoolDefaultSetting extends DefaultSetting<bool> {
  BoolDefaultSetting({
    required super.payloadKey,
    required super.prefsKey,
    required super.builtInDefault,
    super.live,
  });

  @override
  bool? fromPayload(Object? json) => json is bool ? json : null;

  @override
  bool? readStored(SharedPreferences prefs) {
    final stored = prefs.get(prefsKey);
    return stored is bool ? stored : null;
  }

  @override
  Future<void> writeStored(SharedPreferences prefs, bool value) =>
      prefs.setBool(prefsKey, value);
}

/// A choice among [values], named in the payload (`"dark"`) and stored as
/// the enum's `toString()` (`"ThemeMode.dark"`), as the app always did.
class EnumDefaultSetting<E extends Enum> extends DefaultSetting<E> {
  EnumDefaultSetting({
    required super.payloadKey,
    required super.prefsKey,
    required super.builtInDefault,
    required this.values,
    super.live,
  });

  /// Every value the setting can take.
  final List<E> values;

  @override
  E? fromPayload(Object? json) =>
      json is String ? values.asNameMap()[json] : null;

  @override
  E? readStored(SharedPreferences prefs) {
    final stored = prefs.get(prefsKey);
    for (final value in values) {
      if (value.toString() == stored) return value;
    }
    return null;
  }

  @override
  Future<void> writeStored(SharedPreferences prefs, E value) =>
      prefs.setString(prefsKey, value.toString());
}

/// The settings whose defaults come from PostHog, with today's defaults
/// built in.
abstract final class AppDefaultSettings {
  /// "Interfața temei". Dark when nothing says otherwise.
  static final themeMode = EnumDefaultSetting<ThemeMode>(
    payloadKey: 'themeMode',
    prefsKey: ThemeManager.themeModeKey,
    builtInDefault: ThemeMode.dark,
    values: ThemeMode.values,
    live: ThemeManager.themeMode,
  );

  /// "Încărcare în avans".
  static final seekMode = EnumDefaultSetting<SeekMode>(
    payloadKey: 'seekMode',
    prefsKey: SeekModeManager.seekModeKey,
    builtInDefault: SeekMode.twoMinutes,
    values: SeekMode.values,
    live: SeekModeManager.seekMode,
  );

  /// "Conexiune instabilă".
  static final unstableConnection = BoolDefaultSetting(
    payloadKey: 'unstableConnection',
    prefsKey: SeekModeManager.unstableConnectionKey,
    builtInDefault: false,
    live: SeekModeManager.unstableConnection,
  );

  /// "Pornește automat ultima stație". Read at launch only, so a new
  /// default applies from the next launch.
  static final autoStartStation = BoolDefaultSetting(
    payloadKey: 'autoStartStation',
    prefsKey: '_autoStartStation',
    builtInDefault: true,
  );

  /// "Notificări personalizate". Read once at launch (the `personalized_n`
  /// user property), so a new default applies from the next launch.
  static final notificationsEnabled = BoolDefaultSetting(
    payloadKey: 'notificationsEnabled',
    prefsKey: '_notificationsEnabled',
    builtInDefault: true,
  );

  /// "Folosește MP3 cu prioritate". Followed from the next stream load.
  static final preferDirectStreams = BoolDefaultSetting(
    payloadKey: 'preferDirectStreams',
    prefsKey: PlaybackPreferences.preferDirectStreamsKey,
    builtInDefault: false,
    live: PlaybackPreferences.preferDirectStreams,
  );

  /// Every one of them.
  static final List<DefaultSetting> all = [
    themeMode,
    seekMode,
    unstableConnection,
    autoStartStation,
    notificationsEnabled,
    preferDirectStreams,
  ];
}

/// Takes the settings' defaults from the PostHog remote-config flag
/// `mobile-default-settings`, whose JSON payload holds them, e.g.
/// `{"themeMode":"dark","seekMode":"twoMinutes"}`.
///
/// While the user has not changed a setting in Settings, it follows the
/// payload's default, also when that changes later; once they changed it,
/// their choice wins for good. A missing flag, invalid JSON, an unknown key
/// or an invalid value leaves that setting at its built-in default.
///
/// The last payload is cached in [SharedPreferences], so it applies from
/// startup, before flags load.
class DefaultSettings {
  /// Defaults for [settings].
  DefaultSettings(this.settings);

  /// The app-wide instance, for [AppDefaultSettings.all].
  static final DefaultSettings instance =
      DefaultSettings(AppDefaultSettings.all);

  /// PostHog feature flag key.
  static const flagKey = 'mobile-default-settings';

  static const _kPayloadKey = 'mobile_default_settings_payload';

  /// Set once the values stored before "user set" markers existed were
  /// sorted into user choices and defaults.
  static const _kMarkedExistingKey = 'setting_user_set_migrated_v1';

  /// The settings handled.
  final List<DefaultSetting> settings;

  SharedPreferences? _prefs;
  Map<String, Object> _remoteDefaults = const {};

  /// Marks the choices users made before this existed, then applies the
  /// cached defaults to the settings the user has not set.
  ///
  /// Call at startup after [SeekModeManager.initializeFromPrefs], whose
  /// one-time migration rewrites the built-in defaults, and before the UI
  /// reads the settings.
  void initialize(SharedPreferences prefs) {
    _prefs = prefs;
    _markExistingChoices(prefs);
    _remoteDefaults = parsePayload(_cachedPayload(prefs), settings);
    for (final setting in settings) {
      setting.follow(prefs, _remoteDefaults);
    }
  }

  /// Reads the flag once PostHog loaded flags, caches its payload and
  /// applies it. Returns the settings whose value changed.
  Future<List<DefaultSetting>> onFlagsLoaded() async {
    try {
      final result =
          await Posthog().getFeatureFlagResult(flagKey, sendEvent: false);
      return applyPayload(result?.enabled == true ? result?.payload : null);
    } catch (e) {
      developer.log('$flagKey flag read failed: $e');
      return const [];
    }
  }

  /// Caches [payload] and makes the settings the user has not set follow
  /// it. Returns the settings whose value changed.
  List<DefaultSetting> applyPayload(Object? payload) {
    final prefs = _prefs;
    if (prefs == null) return const [];
    _cachePayload(prefs, payload);
    _remoteDefaults = parsePayload(payload, settings);
    return [
      for (final setting in settings)
        if (setting.follow(prefs, _remoteDefaults)) setting,
    ];
  }

  /// Records that the user changed [setting] in Settings: their value wins
  /// over PostHog's default from now on.
  static Future<void> markUserSet(DefaultSetting setting) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(setting.userSetKey, true);
  }

  /// Whether the user changed [setting] in Settings.
  static bool isUserSet(SharedPreferences prefs, DefaultSetting setting) =>
      prefs.get(setting.userSetKey) == true;

  /// The valid defaults in [payload] (a JSON map, or its text), by payload
  /// key. Keys it has no valid value for are left out.
  static Map<String, Object> parsePayload(
    Object? payload,
    List<DefaultSetting> settings,
  ) {
    final map = _decode(payload);
    if (map == null) return const {};
    return {
      for (final setting in settings)
        if (setting.fromPayload(map[setting.payloadKey]) case final value?)
          setting.payloadKey: value,
    };
  }

  /// The value a setting takes: the user's choice once they made one, else
  /// PostHog's default, else the app's own.
  static T effectiveValue<T extends Object>({
    T? userValue,
    T? remoteDefault,
    required T builtInDefault,
  }) =>
      userValue ?? remoteDefault ?? builtInDefault;

  /// Whether a value stored before "user set" markers existed was the
  /// user's choice.
  ///
  /// One different from the built-in default must have been picked. One
  /// equal to it may be the app's own write (the seek-mode migration wrote
  /// the defaults on every install), so it counts as not set.
  static bool isExistingChoice({
    required Object? stored,
    required Object builtInDefault,
  }) =>
      stored != null && stored != builtInDefault;

  void _markExistingChoices(SharedPreferences prefs) {
    if (prefs.getBool(_kMarkedExistingKey) ?? false) return;
    for (final setting in settings) {
      final stored = setting.readStored(prefs);
      if (isExistingChoice(
          stored: stored, builtInDefault: setting.builtInDefault)) {
        unawaited(prefs.setBool(setting.userSetKey, true));
      }
    }
    unawaited(prefs.setBool(_kMarkedExistingKey, true));
  }

  static Object? _cachedPayload(SharedPreferences prefs) =>
      prefs.getString(_kPayloadKey);

  static void _cachePayload(SharedPreferences prefs, Object? payload) {
    if (payload == null) {
      unawaited(prefs.remove(_kPayloadKey));
      return;
    }
    try {
      unawaited(prefs.setString(
          _kPayloadKey, payload is String ? payload : jsonEncode(payload)));
    } catch (e) {
      developer.log('$flagKey payload not cached: $e');
    }
  }

  static Map<Object?, Object?>? _decode(Object? payload) {
    if (payload is Map) return payload;
    if (payload is! String) return null;
    try {
      // A payload sent as JSON text can arrive encoded twice.
      return _decode(jsonDecode(payload));
    } on FormatException {
      return null;
    }
  }
}
