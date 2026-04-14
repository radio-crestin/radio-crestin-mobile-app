import 'dart:convert';
import 'dart:developer' as developer;

import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks how many times the user has played each station.
/// Persists to SharedPreferences. Used by the recommendation algorithm.
class PlayCountService {
  static const _storageKey = 'play_count_store';

  Map<String, int> _playCounts = {};

  Map<String, int> get playCounts => Map.unmodifiable(_playCounts);

  PlayCountService() {
    _load();
  }

  /// Reloads play counts from SharedPreferences.
  /// Called before sorting to ensure the Android Auto engine (separate isolate)
  /// picks up play counts written by the phone engine during the current session.
  void refresh() {
    _load();
  }

  void _load() {
    try {
      final prefs = GetIt.instance<SharedPreferences>();
      final json = prefs.getString(_storageKey);
      if (json != null) {
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        _playCounts = decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
      }
    } catch (e) {
      developer.log("PlayCountService: error loading: $e");
    }
  }

  void incrementPlayCount(String slug) {
    _playCounts[slug] = (_playCounts[slug] ?? 0) + 1;
    _save();
  }

  int getPlayCount(String slug) => _playCounts[slug] ?? 0;

  Future<void> _save() async {
    try {
      final prefs = GetIt.instance<SharedPreferences>();
      await prefs.setString(_storageKey, jsonEncode(_playCounts));
    } catch (e) {
      developer.log("PlayCountService: error saving: $e");
    }
  }
}
