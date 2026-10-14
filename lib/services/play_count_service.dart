import 'dart:async';
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

/// Counts a picked station as played once its audio has run for
/// [threshold] without stopping.
///
/// Passing through stations (steering-wheel next/previous, an autoplay that
/// is paused right away) is not listening: counting it would fill "Most
/// played" with stations the listener only skipped over.
class PlayCountTracker {
  PlayCountTracker({
    required this.onCounted,
    this.threshold = const Duration(seconds: 30),
  });

  final void Function(String slug) onCounted;
  final Duration threshold;

  String? _pendingSlug;
  Timer? _timer;

  /// [slug] was picked; it counts once it has played for [threshold].
  void stationPicked(String slug) {
    _cancelTimer();
    _pendingSlug = slug;
  }

  /// The picked station's audio started or stopped playing.
  void playingChanged(bool playing) {
    if (!playing) {
      _cancelTimer();
      return;
    }
    final slug = _pendingSlug;
    if (slug == null || _timer != null) return;
    _timer = Timer(threshold, () {
      _timer = null;
      _pendingSlug = null;
      onCounted(slug);
    });
  }

  void dispose() => _cancelTimer();

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
