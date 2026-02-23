import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SeekMode { instant, twoMinutes, fiveMinutes }

class SeekModeManager {
  static const String _seekModeKey = 'seek_mode';
  static final _seekModeNotifier = ValueNotifier<SeekMode>(SeekMode.twoMinutes);

  static ValueNotifier<SeekMode> get seekMode => _seekModeNotifier;

  static Duration get currentOffset {
    switch (_seekModeNotifier.value) {
      case SeekMode.instant:
        return Duration.zero;
      case SeekMode.twoMinutes:
        return const Duration(minutes: 2);
      case SeekMode.fiveMinutes:
        return const Duration(minutes: 5);
    }
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

  static void initializeFromPrefs(SharedPreferences prefs) {
    final seekModeString = prefs.getString(_seekModeKey);
    _seekModeNotifier.value = _parseSeekMode(seekModeString);
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
