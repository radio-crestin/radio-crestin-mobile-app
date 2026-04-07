import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SeekMode { instant, twoMinutes, fiveMinutes }

class SeekModeManager {
  static const String _seekModeKey = 'seek_mode';
  static const String _unstableConnectionKey = 'unstable_connection';
  static final _seekModeNotifier = ValueNotifier<SeekMode>(SeekMode.twoMinutes);
  static final _unstableConnectionNotifier = ValueNotifier<bool>(false);
  static final _carConnectedNotifier = ValueNotifier<bool>(false);

  static ValueNotifier<SeekMode> get seekMode => _seekModeNotifier;
  static ValueNotifier<bool> get unstableConnection => _unstableConnectionNotifier;
  static ValueNotifier<bool> get carConnected => _carConnectedNotifier;

  static bool get isUnstableConnection => _unstableConnectionNotifier.value;
  static bool get isCarConnected => _carConnectedNotifier.value;

  static Duration get currentOffset {
    // When car is connected or unstable connection is active, always use 5 minutes
    if (_carConnectedNotifier.value || _unstableConnectionNotifier.value) {
      return const Duration(minutes: 5);
    }
    switch (_seekModeNotifier.value) {
      case SeekMode.instant:
        return Duration.zero;
      case SeekMode.twoMinutes:
        return const Duration(minutes: 2);
      case SeekMode.fiveMinutes:
        return const Duration(minutes: 5);
    }
  }

  /// The effective seek mode considering car connection and unstable connection overrides.
  static SeekMode get effectiveSeekMode {
    if (_carConnectedNotifier.value || _unstableConnectionNotifier.value) return SeekMode.fiveMinutes;
    return _seekModeNotifier.value;
  }

  static void changeCarConnected(bool connected) {
    _carConnectedNotifier.value = connected;
  }

  static Future<void> saveSeekMode(SeekMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_seekModeKey, mode.toString());
  }

  static Future<SeekMode> loadSeekMode() async {
    final prefs = await SharedPreferences.getInstance();
    final seekModeString = prefs.getString(_seekModeKey);
    return _parseSeekMode(seekModeString);
  }

  static void changeSeekMode(SeekMode mode) {
    _seekModeNotifier.value = mode;
  }

  static Future<void> saveUnstableConnection(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_unstableConnectionKey, enabled);
  }

  static void changeUnstableConnection(bool enabled) {
    _unstableConnectionNotifier.value = enabled;
  }

  static void initializeFromPrefs(SharedPreferences prefs) {
    final seekModeString = prefs.getString(_seekModeKey);
    _seekModeNotifier.value = _parseSeekMode(seekModeString);
    _unstableConnectionNotifier.value = prefs.getBool(_unstableConnectionKey) ?? false;
  }

  static SeekMode _parseSeekMode(String? seekModeString) {
    switch (seekModeString) {
      case 'SeekMode.instant':
        return SeekMode.instant;
      case 'SeekMode.twoMinutes':
        return SeekMode.twoMinutes;
      case 'SeekMode.fiveMinutes':
        return SeekMode.fiveMinutes;
      default:
        return SeekMode.twoMinutes;
    }
  }
}
