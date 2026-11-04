import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Playback settings read synchronously by the audio handler.
class PlaybackPreferences {
  PlaybackPreferences._();

  /// Where "use MP3 streams first" is stored.
  static const preferDirectStreamsKey = 'prefer_direct_streams';

  static final _preferDirectStreams = ValueNotifier<bool>(false);

  /// The "use MP3 streams first" setting: a station loads its direct (MP3)
  /// streams before its HLS ones.
  ///
  /// Read at each stream load (a station switch, a reconnect), so a change
  /// applies from the next one; the playing stream is not reloaded.
  static ValueNotifier<bool> get preferDirectStreams => _preferDirectStreams;

  /// Whether stream loads try direct streams before HLS: the setting is on,
  /// or the platform's player plays HLS unreliably.
  static bool get directStreamsFirst =>
      _preferDirectStreams.value || platformPrefersDirectStreams;

  /// Whether this platform always loads direct streams first, whatever the
  /// setting: Windows and Linux play through just_audio_media_kit (libmpv
  /// ~2023-09), whose support for HLS v9 with query params is flaky.
  static bool get platformPrefersDirectStreams =>
      Platform.isWindows || Platform.isLinux;

  /// Reads the stored setting. Call once at startup.
  static void initializeFromPrefs(SharedPreferences prefs) {
    _preferDirectStreams.value = prefs.getBool(preferDirectStreamsKey) ?? false;
  }

  /// Stores [enabled] for the next launches.
  static Future<void> savePreferDirectStreams(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(preferDirectStreamsKey, enabled);
  }

  /// Applies [enabled] from the next stream load.
  static void changePreferDirectStreams(bool enabled) {
    _preferDirectStreams.value = enabled;
  }
}
