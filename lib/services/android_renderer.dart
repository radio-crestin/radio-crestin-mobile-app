import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The renderer a developer picked in Settings for the next launches.
enum RendererChoice {
  /// Follows the `android-stable-renderer` PostHog flag.
  automatic,

  /// Skia on OpenGL: slower, but stable where Impeller is not.
  skia,

  /// Impeller, Flutter's default.
  impeller,
}

/// Picks Flutter's renderer on Android: Impeller, as by default, or the
/// older Skia, on devices where Impeller flickers or blacks out the screen
/// (cheap car head units and tablets with weak Vulkan drivers).
///
/// The renderer is fixed when the engine starts, before any Dart runs, so
/// `MainApplication.kt` reads [useSkiaKey] at process start: what is decided
/// here applies from the next launch. The Settings choice wins; on
/// [RendererChoice.automatic] the PostHog flag [flagKey] decides (its last
/// value is cached), and a missing flag means Impeller.
class AndroidRenderer {
  /// The parameters exist for tests: whether the platform is Android, and
  /// the call that reads the live flag (null when the flag is missing).
  AndroidRenderer({bool? supported, Future<bool?> Function()? readFlag})
      : supported = supported ?? Platform.isAndroid,
        _readFlag = readFlag ?? _readLiveFlag;

  static AndroidRenderer _instance = AndroidRenderer();

  /// The app-wide instance.
  static AndroidRenderer get instance => _instance;

  /// Replaces [instance] in tests.
  @visibleForTesting
  static set debugInstance(AndroidRenderer renderer) => _instance = renderer;

  /// PostHog feature flag key: on for a device, it gets Skia.
  static const flagKey = 'android-stable-renderer';

  /// Whether the next launch uses Skia.
  ///
  /// Read natively as `flutter.android_renderer_use_skia` from the
  /// `FlutterSharedPreferences` file (`MainApplication.kt`): rename both
  /// together.
  static const useSkiaKey = 'android_renderer_use_skia';

  static const _kChoiceKey = 'android_renderer_choice';
  static const _kFlagKey = 'android_stable_renderer_flag';
  static const _channel = MethodChannel('com.radiocrestin.app');

  /// Whether the renderer can be picked here: on Android only. iOS and
  /// macOS have Impeller only.
  final bool supported;

  final Future<bool?> Function() _readFlag;
  SharedPreferences? _prefs;
  RendererChoice _choice = RendererChoice.automatic;
  bool _flagOn = false;
  bool _launchUsesSkia = false;

  /// The renderer picked in Settings.
  RendererChoice get choice => _choice;

  /// Whether this launch asked the engine for Skia.
  bool get launchUsesSkia => _launchUsesSkia;

  /// Whether the next launch asks the engine for Skia.
  bool get nextLaunchUsesSkia =>
      resolveUseSkia(choice: _choice, flagOn: _flagOn);

  /// Reads what this launch used and the cached choice and flag. Call
  /// before PostHog setup.
  Future<void> loadCache(SharedPreferences prefs) async {
    if (!supported) return;
    _prefs = prefs;
    _launchUsesSkia = prefs.getBool(useSkiaKey) ?? false;
    _choice = RendererChoice.values.asNameMap()[prefs.getString(_kChoiceKey)] ??
        RendererChoice.automatic;
    _flagOn = prefs.getBool(_kFlagKey) ?? false;
  }

  /// Re-reads the flag once PostHog loaded flags, and stores the result for
  /// the next launch.
  Future<void> onFlagsLoaded() async {
    if (!supported) return;
    try {
      _flagOn = await _readFlag() ?? false;
      await _prefs?.setBool(_kFlagKey, _flagOn);
      await _storeNextLaunch();
    } catch (e) {
      developer.log('$flagKey flag read failed: $e');
    }
  }

  /// Saves the renderer picked in Settings, for the next launch.
  Future<void> setChoice(RendererChoice choice) async {
    if (!supported) return;
    _choice = choice;
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(_kChoiceKey, choice.name);
    await _storeNextLaunch();
  }

  /// Ends the app's process and opens the app again, so the next launch's
  /// renderer applies at once. Closing the screen is not enough: the
  /// process, and its engine, outlive it while the radio plays.
  Future<void> restartApp() => _channel.invokeMethod<void>('restartApp');

  /// Pure: the Settings choice wins; on automatic, the flag decides.
  static bool resolveUseSkia({
    required RendererChoice choice,
    required bool flagOn,
  }) =>
      switch (choice) {
        RendererChoice.skia => true,
        RendererChoice.impeller => false,
        RendererChoice.automatic => flagOn,
      };

  Future<void> _storeNextLaunch() async =>
      _prefs?.setBool(useSkiaKey, nextLaunchUsesSkia);

  static Future<bool?> _readLiveFlag() async {
    final result =
        await Posthog().getFeatureFlagResult(flagKey, sendEvent: false);
    return result?.enabled;
  }
}
