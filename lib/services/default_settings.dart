import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart' show ThemeMode, ValueNotifier;
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../seek_mode_manager.dart';
import '../theme_manager.dart';

/// A setting whose default comes from its own PostHog flag until the user
/// changes it.
///
/// The flag is multivariate, each variant named after the value it gives
/// (see [fromVariant]). Its value stays stored under [prefsKey], where the
/// code that reads the setting finds it: while the user has not changed
/// it, that is the default in force, rewritten whenever the default
/// changes.
abstract class DefaultSetting<T extends Object> {
  DefaultSetting({
    required this.id,
    required this.flagKey,
    required this.prefsKey,
    required this.builtInDefault,
    this.live,
  });

  /// Names the setting in the keys stored for it.
  final String id;

  /// The PostHog flag that gives its default.
  final String flagKey;

  /// Where its value is stored.
  final String prefsKey;

  /// The default when PostHog gives none: the app's own.
  final T builtInDefault;

  /// The notifier the app follows the setting with, if it follows it live.
  final ValueNotifier<T>? live;

  /// Where "the user changed it in Settings" is stored.
  String get userSetKey => 'setting_user_set_$id';

  /// Where the last variant of [flagKey] is cached.
  String get cachedVariantKey => 'default_setting_variant_$id';

  /// The value a flag [variant] gives, or null when it names none.
  T? fromVariant(String? variant);

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
    final remote = remoteDefaults[id];
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

/// An on/off setting, whose flag variants are `on` and `off`.
class BoolDefaultSetting extends DefaultSetting<bool> {
  BoolDefaultSetting({
    required super.id,
    required super.flagKey,
    required super.prefsKey,
    required super.builtInDefault,
    super.live,
  });

  @override
  bool? fromVariant(String? variant) => switch (variant) {
        'on' => true,
        'off' => false,
        _ => null,
      };

  @override
  bool? readStored(SharedPreferences prefs) {
    final stored = prefs.get(prefsKey);
    return stored is bool ? stored : null;
  }

  @override
  Future<void> writeStored(SharedPreferences prefs, bool value) =>
      prefs.setBool(prefsKey, value);
}

/// A choice among [values], whose flag variants are their names (`dark`),
/// stored as the enum's `toString()` (`ThemeMode.dark`), as the app always
/// did.
class EnumDefaultSetting<E extends Enum> extends DefaultSetting<E> {
  EnumDefaultSetting({
    required super.id,
    required super.flagKey,
    required super.prefsKey,
    required super.builtInDefault,
    required this.values,
    super.live,
  });

  /// Every value the setting can take.
  final List<E> values;

  @override
  E? fromVariant(String? variant) => values.asNameMap()[variant];

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
/// built in. Their flags carry the PostHog tag `default-settings`.
abstract final class AppDefaultSettings {
  /// "Interfața temei". Dark when nothing says otherwise.
  static final themeMode = EnumDefaultSetting<ThemeMode>(
    id: 'themeMode',
    flagKey: 'default-theme-mode',
    prefsKey: ThemeManager.themeModeKey,
    builtInDefault: ThemeMode.dark,
    values: ThemeMode.values,
    live: ThemeManager.themeMode,
  );

  /// "Încărcare în avans".
  static final seekMode = EnumDefaultSetting<SeekMode>(
    id: 'seekMode',
    flagKey: 'default-seek-mode',
    prefsKey: SeekModeManager.seekModeKey,
    builtInDefault: SeekMode.twoMinutes,
    values: SeekMode.values,
    live: SeekModeManager.seekMode,
  );

  /// "Conexiune instabilă".
  static final unstableConnection = BoolDefaultSetting(
    id: 'unstableConnection',
    flagKey: 'default-unstable-connection',
    prefsKey: SeekModeManager.unstableConnectionKey,
    builtInDefault: false,
    live: SeekModeManager.unstableConnection,
  );

  /// "Pornește automat ultima stație". Read at launch only, so a new
  /// default applies from the next launch.
  static final autoStartStation = BoolDefaultSetting(
    id: 'autoStartStation',
    flagKey: 'default-auto-start-station',
    prefsKey: '_autoStartStation',
    builtInDefault: true,
  );

  /// "Notificări personalizate". Read once at launch (the `personalized_n`
  /// user property), so a new default applies from the next launch.
  static final notificationsEnabled = BoolDefaultSetting(
    id: 'notificationsEnabled',
    flagKey: 'default-notifications-enabled',
    prefsKey: '_notificationsEnabled',
    builtInDefault: true,
  );

  // "Folosește MP3 cu prioritate" is not here: a developer-mode setting,
  // off unless the user turns it on (see `PlaybackPreferences`).

  /// Every one of them.
  static final List<DefaultSetting> all = [
    themeMode,
    seekMode,
    unstableConnection,
    autoStartStation,
    notificationsEnabled,
  ];
}

/// Takes the settings' defaults from their PostHog flags, one per setting
/// (see [DefaultSetting.flagKey]).
///
/// While the user has not changed a setting in Settings, it follows its
/// flag's default, also when that changes later; once they changed it,
/// their choice wins for good. A flag that is missing, off, or on a variant
/// that names no value leaves that setting at its built-in default.
///
/// Each flag's last variant is cached in [SharedPreferences], so it applies
/// from startup, before flags load.
class DefaultSettings {
  /// Defaults for [settings]. [readVariant] gives a flag's variant (null
  /// when the flag is off or missing); it exists for tests.
  DefaultSettings(this.settings,
      {Future<String?> Function(String)? readVariant})
      : _readVariant = readVariant ?? _readLiveVariant;

  /// The app-wide instance, for [AppDefaultSettings.all].
  static final DefaultSettings instance =
      DefaultSettings(AppDefaultSettings.all);

  /// Where the single JSON flag `mobile-default-settings`, which these
  /// flags replaced, cached its payload.
  static const _kLegacyPayloadKey = 'mobile_default_settings_payload';

  /// Set once the values stored before "user set" markers existed were
  /// sorted into user choices and defaults.
  static const _kMarkedExistingKey = 'setting_user_set_migrated_v1';

  /// The settings handled.
  final List<DefaultSetting> settings;

  final Future<String?> Function(String flagKey) _readVariant;

  SharedPreferences? _prefs;
  Map<String, Object> _remoteDefaults = const {};

  static Future<String?> _readLiveVariant(String flagKey) async {
    final result =
        await Posthog().getFeatureFlagResult(flagKey, sendEvent: false);
    return result?.enabled == true ? result?.variant : null;
  }

  /// Marks the choices users made before this existed, then applies the
  /// cached defaults to the settings the user has not set.
  ///
  /// Call at startup after [SeekModeManager.initializeFromPrefs], whose
  /// one-time migration rewrites the built-in defaults, and before the UI
  /// reads the settings.
  void initialize(SharedPreferences prefs) {
    _prefs = prefs;
    _markExistingChoices(prefs);
    if (prefs.containsKey(_kLegacyPayloadKey)) {
      unawaited(prefs.remove(_kLegacyPayloadKey));
    }
    _remoteDefaults = parseVariants({
      for (final setting in settings)
        setting.id: prefs.getString(setting.cachedVariantKey),
    }, settings);
    for (final setting in settings) {
      setting.follow(prefs, _remoteDefaults);
    }
  }

  /// Reads every setting's flag once PostHog loaded flags, caches the
  /// variants and applies them. Returns the settings whose value changed.
  Future<List<DefaultSetting>> onFlagsLoaded() async {
    final variants = <String, String?>{};
    for (final setting in settings) {
      try {
        variants[setting.id] = await _readVariant(setting.flagKey);
      } catch (e) {
        developer.log('${setting.flagKey} flag read failed: $e');
        // Keeps the cached variant rather than dropping to the built-in.
        variants[setting.id] = _prefs?.getString(setting.cachedVariantKey);
      }
    }
    return applyVariants(variants);
  }

  /// Caches the flag [variants], by setting id, and makes the settings the
  /// user has not set follow them. Returns the settings whose value changed.
  List<DefaultSetting> applyVariants(Map<String, String?> variants) {
    final prefs = _prefs;
    if (prefs == null) return const [];
    for (final setting in settings) {
      _cacheVariant(prefs, setting, variants[setting.id]);
    }
    _remoteDefaults = parseVariants(variants, settings);
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

  /// The defaults the flag [variants] give, by setting id. Settings whose
  /// variant names no value are left out.
  static Map<String, Object> parseVariants(
    Map<String, String?> variants,
    List<DefaultSetting> settings,
  ) =>
      {
        for (final setting in settings)
          if (setting.fromVariant(variants[setting.id]) case final value?)
            setting.id: value,
      };

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

  static void _cacheVariant(
    SharedPreferences prefs,
    DefaultSetting setting,
    String? variant,
  ) {
    final key = setting.cachedVariantKey;
    unawaited(
        variant == null ? prefs.remove(key) : prefs.setString(key, variant));
  }
}
