import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum StationSortOption { recommended, mostPlayed, listeners, rating, alphabetical }

class StationSortLabels {
  static const Map<StationSortOption, String> labels = {
    StationSortOption.recommended: 'Pentru tine',
    StationSortOption.mostPlayed: 'Cele mai ascultate',
    StationSortOption.listeners: 'Ascultători',
    StationSortOption.rating: 'Rating',
    StationSortOption.alphabetical: 'Alfabetic',
  };

  static const Map<StationSortOption, IconData> icons = {
    StationSortOption.recommended: Icons.auto_awesome,
    StationSortOption.mostPlayed: Icons.music_note_rounded,
    StationSortOption.listeners: Icons.people_rounded,
    StationSortOption.rating: Icons.star_rounded,
    StationSortOption.alphabetical: Icons.sort_by_alpha_rounded,
  };
}

class _StationScore {
  final double score;
  final int listeners;
  final double rating;

  const _StationScore({required this.score, required this.listeners, required this.rating});
}

class StationSortResult {
  final List<Station> sorted;
  final String? stationOfDaySlug;
  final Set<String> mostPlayedSlugs;

  const StationSortResult({
    required this.sorted,
    this.stationOfDaySlug,
    this.mostPlayedSlugs = const {},
  });
}

class StationSortService {
  static const _storageKey = 'station_sort_preference';

  static StationSortOption loadSavedSort() {
    try {
      final prefs = GetIt.instance<SharedPreferences>();
      final saved = prefs.getString(_storageKey);
      if (saved != null) {
        return StationSortOption.values.firstWhere(
          (e) => e.name == saved,
          orElse: () => StationSortOption.recommended,
        );
      }
    } catch (_) {}
    return StationSortOption.recommended;
  }

  static Future<void> saveSortOption(StationSortOption option) async {
    final prefs = GetIt.instance<SharedPreferences>();
    await prefs.setString(_storageKey, option.name);
  }

  /// Computes a review score for a station: avgRating * numReviews.
  static double _reviewScore(Station station) {
    final reviews = station.rawStationData.reviews;
    if (reviews.isEmpty) return 0;
    final sum = reviews.fold<double>(0, (s, r) => s + (r.stars ?? 0));
    final avg = sum / reviews.length;
    return avg * reviews.length;
  }

  /// Builds a score snapshot: 50% normalized reviews + 50% normalized listeners.
  static Map<String, _StationScore> _buildScoreSnapshot(List<Station> stations) {
    if (stations.isEmpty) return {};

    double maxReviewRaw = 0;
    double maxListenersRaw = 0;
    for (final s in stations) {
      final r = _reviewScore(s);
      if (r > maxReviewRaw) maxReviewRaw = r;
      final l = (s.totalListeners ?? 0).toDouble();
      if (l > maxListenersRaw) maxListenersRaw = l;
    }
    final maxReview = max(maxReviewRaw, 1.0);
    final maxListeners = max(maxListenersRaw, 1.0);

    final snapshot = <String, _StationScore>{};
    for (final s in stations) {
      final review = _reviewScore(s);
      final listeners = (s.totalListeners ?? 0).toDouble();
      snapshot[s.slug] = _StationScore(
        score: (review / maxReview) * 0.5 + (listeners / maxListeners) * 0.5,
        listeners: s.totalListeners ?? 0,
        rating: review,
      );
    }
    return snapshot;
  }

  static List<Station> _sortByScore(List<Station> stations, Map<String, _StationScore> scores) {
    final sorted = List<Station>.from(stations);
    sorted.sort((a, b) => (scores[b.slug]?.score ?? 0).compareTo(scores[a.slug]?.score ?? 0));
    return sorted;
  }

  /// Deterministic "station of the day" — rotates daily through all stations.
  static String? _getStationOfTheDay(List<Station> stations) {
    if (stations.isEmpty) return null;
    final stableOrder = List<Station>.from(stations)
      ..sort((a, b) => a.slug.compareTo(b.slug));
    final now = DateTime.now();
    final start = DateTime(now.year, 1, 1);
    final dayOfYear = now.difference(start).inDays;
    return stableOrder[dayOfYear % stableOrder.length].slug;
  }

  /// Sort stations using the selected algorithm.
  static StationSortResult sort({
    required List<Station> stations,
    required StationSortOption sortBy,
    required Map<String, int> playCounts,
    required List<String> favoriteSlugs,
  }) {
    final scores = _buildScoreSnapshot(stations);

    switch (sortBy) {
      case StationSortOption.recommended:
        return _sortRecommended(stations, playCounts, favoriteSlugs, scores);

      case StationSortOption.mostPlayed:
        return _sortMostPlayed(stations, playCounts, scores);

      case StationSortOption.listeners:
        final sorted = List<Station>.from(stations)
          ..sort((a, b) => (scores[b.slug]?.listeners ?? 0).compareTo(scores[a.slug]?.listeners ?? 0));
        return StationSortResult(sorted: sorted);

      case StationSortOption.rating:
        final sorted = List<Station>.from(stations)
          ..sort((a, b) => (scores[b.slug]?.rating ?? 0).compareTo(scores[a.slug]?.rating ?? 0));
        return StationSortResult(sorted: sorted);

      case StationSortOption.alphabetical:
        final sorted = List<Station>.from(stations)
          ..sort((a, b) => a.title.compareTo(b.title));
        return StationSortResult(sorted: sorted);
    }
  }

  /// "Pentru tine" algorithm:
  /// 1. Station of the day (deterministic daily rotation)
  /// 2-4. Top 3 most-played by user (excluding favorites, backfilled by score)
  /// 5+. Remaining sorted by score (50% reviews + 50% listeners)
  static StationSortResult _sortRecommended(
    List<Station> stations,
    Map<String, int> playCounts,
    List<String> favoriteSlugs,
    Map<String, _StationScore> scores,
  ) {
    final stationOfDaySlug = _getStationOfTheDay(stations);
    final favoriteSet = favoriteSlugs.toSet();

    // Positions 2-4: top 3 most-played (excluding station of day and favorites)
    final placedSlugs = <String>{};
    if (stationOfDaySlug != null) placedSlugs.add(stationOfDaySlug);

    final stationSlugs = stations.map((s) => s.slug).toSet();
    final mostPlayedEntries = playCounts.entries
        .where((e) => !placedSlugs.contains(e.key) && !favoriteSet.contains(e.key) && stationSlugs.contains(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final mostPlayedSlugs = mostPlayedEntries.take(3).map((e) => e.key).toList();

    // Backfill with top-scored if fewer than 3
    if (mostPlayedSlugs.length < 3) {
      final alreadyPlaced = {...placedSlugs, ...mostPlayedSlugs};
      final candidates = stations
          .where((s) => !alreadyPlaced.contains(s.slug) && !favoriteSet.contains(s.slug))
          .toList();
      final topByScore = _sortByScore(candidates, scores);
      for (final s in topByScore) {
        if (mostPlayedSlugs.length >= 3) break;
        mostPlayedSlugs.add(s.slug);
      }
    }

    final allSpecialSlugs = {
      if (stationOfDaySlug != null) stationOfDaySlug,
      ...mostPlayedSlugs,
    };
    final remaining = _sortByScore(
      stations.where((s) => !allSpecialSlugs.contains(s.slug)).toList(),
      scores,
    );

    final findStation = <String, Station>{for (final s in stations) s.slug: s};
    final result = <Station>[];

    // Position 1: station of the day
    if (stationOfDaySlug != null && findStation.containsKey(stationOfDaySlug)) {
      result.add(findStation[stationOfDaySlug]!);
    }

    // Positions 2-4: most played by user
    for (final slug in mostPlayedSlugs) {
      if (findStation.containsKey(slug)) {
        result.add(findStation[slug]!);
      }
    }

    // Remaining
    result.addAll(remaining);

    return StationSortResult(
      sorted: result,
      stationOfDaySlug: stationOfDaySlug,
      mostPlayedSlugs: mostPlayedSlugs.toSet(),
    );
  }

  static StationSortResult _sortMostPlayed(
    List<Station> stations,
    Map<String, int> playCounts,
    Map<String, _StationScore> scores,
  ) {
    final played = stations.where((s) => (playCounts[s.slug] ?? 0) > 0).toList()
      ..sort((a, b) => (playCounts[b.slug] ?? 0).compareTo(playCounts[a.slug] ?? 0));
    final notPlayed = stations.where((s) => (playCounts[s.slug] ?? 0) == 0).toList();
    final sortedNotPlayed = _sortByScore(notPlayed, scores);
    return StationSortResult(sorted: [...played, ...sortedNotPlayed]);
  }
}
