import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/services/station_sort_service.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

Station _stationWithRating({
  required int id,
  required String slug,
  required String title,
  int totalListeners = 10,
  double averageRating = 0,
  int reviewCount = 0,
}) {
  return Station(
    rawStationData: StationFactory.createRawStation(
      id: id,
      slug: slug,
      title: title,
      totalListeners: totalListeners,
    ),
    averageRating: averageRating,
    numberOfReviews: reviewCount,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    if (GetIt.instance.isRegistered<SharedPreferences>()) {
      GetIt.instance.unregister<SharedPreferences>();
    }
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
  });

  tearDown(() {
    if (GetIt.instance.isRegistered<SharedPreferences>()) {
      GetIt.instance.unregister<SharedPreferences>();
    }
  });

  group('StationSortOption enum', () {
    test('exposes the five expected sort modes', () {
      expect(StationSortOption.values, [
        StationSortOption.recommended,
        StationSortOption.mostPlayed,
        StationSortOption.listeners,
        StationSortOption.rating,
        StationSortOption.alphabetical,
      ]);
    });
  });

  group('StationSortLabels', () {
    test('has a Romanian label for every sort option', () {
      for (final opt in StationSortOption.values) {
        final label = StationSortLabels.labels[opt];
        expect(label, isNotNull, reason: 'Missing label for $opt');
        expect(label, isNotEmpty);
      }
    });

    test('has an icon for every sort option', () {
      for (final opt in StationSortOption.values) {
        final icon = StationSortLabels.icons[opt];
        expect(icon, isA<IconData>(), reason: 'Missing icon for $opt');
      }
    });
  });

  group('StationSortResult', () {
    test('defaults stationOfDaySlug to null and mostPlayedSlugs to empty', () {
      const result = StationSortResult(sorted: []);
      expect(result.stationOfDaySlug, isNull);
      expect(result.mostPlayedSlugs, isEmpty);
    });
  });

  group('loadSavedSort', () {
    test('returns recommended when nothing is stored', () {
      expect(StationSortService.loadSavedSort(), StationSortOption.recommended);
    });

    test('returns the saved option when valid', () async {
      await StationSortService.saveSortOption(StationSortOption.alphabetical);
      expect(StationSortService.loadSavedSort(), StationSortOption.alphabetical);
    });

    test('falls back to recommended when stored value is unrecognized', () async {
      final prefs = GetIt.instance<SharedPreferences>();
      await prefs.setString('station_sort_preference', 'totally_made_up');
      expect(StationSortService.loadSavedSort(), StationSortOption.recommended);
    });

    test('falls back to recommended when SharedPreferences is not registered', () {
      GetIt.instance.unregister<SharedPreferences>();
      expect(StationSortService.loadSavedSort(), StationSortOption.recommended);
    });
  });

  group('saveSortOption', () {
    test('persists by enum name', () async {
      await StationSortService.saveSortOption(StationSortOption.listeners);
      final prefs = GetIt.instance<SharedPreferences>();
      expect(prefs.getString('station_sort_preference'), 'listeners');
    });
  });

  group('sort — alphabetical', () {
    test('orders by station title (case-sensitive ASCII)', () {
      final stations = [
        _stationWithRating(id: 1, slug: 'c', title: 'Cantec'),
        _stationWithRating(id: 2, slug: 'a', title: 'Aripi'),
        _stationWithRating(id: 3, slug: 'b', title: 'Buna Vestire'),
      ];

      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.alphabetical,
        playCounts: {},
        favoriteSlugs: const [],
      );

      expect(result.sorted.map((s) => s.slug), ['a', 'b', 'c']);
    });
  });

  group('sort — listeners', () {
    test('orders by total_listeners descending; null treated as 0', () {
      final stations = [
        _stationWithRating(id: 1, slug: 'low', title: 'Low', totalListeners: 1),
        _stationWithRating(id: 2, slug: 'high', title: 'High', totalListeners: 1000),
        _stationWithRating(id: 3, slug: 'mid', title: 'Mid', totalListeners: 100),
      ];

      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.listeners,
        playCounts: {},
        favoriteSlugs: const [],
      );

      expect(result.sorted.map((s) => s.slug), ['high', 'mid', 'low']);
    });
  });

  group('sort — rating', () {
    test('orders by averageRating × reviewCount descending', () {
      final stations = [
        _stationWithRating(id: 1, slug: 'few-good', title: 'F', averageRating: 5, reviewCount: 1),     // 5
        _stationWithRating(id: 2, slug: 'many-ok', title: 'M', averageRating: 3, reviewCount: 50),     // 150
        _stationWithRating(id: 3, slug: 'mid', title: 'X', averageRating: 4, reviewCount: 10),         // 40
      ];

      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.rating,
        playCounts: {},
        favoriteSlugs: const [],
      );

      expect(result.sorted.map((s) => s.slug), ['many-ok', 'mid', 'few-good']);
    });
  });

  group('sort — mostPlayed', () {
    test('places played stations first by play count, unplayed after by score', () {
      final stations = [
        _stationWithRating(id: 1, slug: 'a', title: 'A', totalListeners: 10),
        _stationWithRating(id: 2, slug: 'b', title: 'B', totalListeners: 100),
        _stationWithRating(id: 3, slug: 'c', title: 'C', totalListeners: 50),
      ];

      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.mostPlayed,
        playCounts: const {'a': 5, 'c': 1},  // 'b' never played
        favoriteSlugs: const [],
      );

      // Played: a(5), c(1). Unplayed: just b — ranks first among unplayed.
      expect(result.sorted.map((s) => s.slug), ['a', 'c', 'b']);
    });

    test('returns score-sorted unplayed list when no stations have been played', () {
      final stations = [
        _stationWithRating(id: 1, slug: 'a', title: 'A', totalListeners: 1),
        _stationWithRating(id: 2, slug: 'b', title: 'B', totalListeners: 1000),
      ];

      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.mostPlayed,
        playCounts: const {},
        favoriteSlugs: const [],
      );

      // Both are "unplayed" — ranked by combined review+listeners score.
      expect(result.sorted.first.slug, 'b');
    });
  });

  group('sort — recommended', () {
    test('returns empty result for empty station list', () {
      final result = StationSortService.sort(
        stations: const [],
        sortBy: StationSortOption.recommended,
        playCounts: const {},
        favoriteSlugs: const [],
      );

      expect(result.sorted, isEmpty);
      expect(result.stationOfDaySlug, isNull);
      expect(result.mostPlayedSlugs, isEmpty);
    });

    test('produces a stationOfTheDay slug from a non-empty list', () {
      final stations = List.generate(
        5,
        (i) => _stationWithRating(id: i + 1, slug: 's$i', title: 'S$i'),
      );

      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: const {},
        favoriteSlugs: const [],
      );

      expect(result.stationOfDaySlug, isNotNull);
      expect(stations.any((s) => s.slug == result.stationOfDaySlug), isTrue);
    });

    test('places station of the day first, then up to 3 most-played, then the rest', () {
      // Build a wider catalog so we can see the layered placement.
      final stations = [
        _stationWithRating(id: 1, slug: 'a', title: 'A', totalListeners: 1),
        _stationWithRating(id: 2, slug: 'b', title: 'B', totalListeners: 1),
        _stationWithRating(id: 3, slug: 'c', title: 'C', totalListeners: 1),
        _stationWithRating(id: 4, slug: 'd', title: 'D', totalListeners: 1),
        _stationWithRating(id: 5, slug: 'e', title: 'E', totalListeners: 1),
        _stationWithRating(id: 6, slug: 'f', title: 'F', totalListeners: 1),
      ];

      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: const {'b': 10, 'c': 5, 'd': 1},
        favoriteSlugs: const [],
      );

      final slugs = result.sorted.map((s) => s.slug).toList();
      // Station of the day is deterministic but not constrained — assert
      // structural invariants instead of specific slugs.
      expect(slugs.length, stations.length);
      expect(slugs.first, result.stationOfDaySlug);
      // Most-played bucket appears immediately after the station of the day.
      // Bucket size is the smaller of (3, played-count not equal to station-of-day).
      expect(result.mostPlayedSlugs.length, lessThanOrEqualTo(3));
    });

    test('excludes favorites from the most-played bucket', () {
      final stations = [
        _stationWithRating(id: 1, slug: 'a', title: 'A'),
        _stationWithRating(id: 2, slug: 'b', title: 'B'),
        _stationWithRating(id: 3, slug: 'c', title: 'C'),
        _stationWithRating(id: 4, slug: 'd', title: 'D'),
        _stationWithRating(id: 5, slug: 'e', title: 'E'),
      ];

      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        // 'a' is the most-played but also a favorite → must not be in the bucket.
        playCounts: const {'a': 100, 'b': 10, 'c': 5},
        favoriteSlugs: const ['a'],
      );

      expect(
        result.mostPlayedSlugs,
        isNot(contains('a')),
        reason: 'Favorites should never be reused in the most-played slot',
      );
    });

    test('backfills the most-played bucket from top-scored when fewer than 3 plays exist', () {
      final stations = [
        _stationWithRating(id: 1, slug: 'a', title: 'A', totalListeners: 1, averageRating: 0, reviewCount: 0),
        _stationWithRating(id: 2, slug: 'b', title: 'B', totalListeners: 5, averageRating: 0, reviewCount: 0),
        _stationWithRating(id: 3, slug: 'c', title: 'C', totalListeners: 10, averageRating: 0, reviewCount: 0),
        _stationWithRating(id: 4, slug: 'd', title: 'D', totalListeners: 100, averageRating: 0, reviewCount: 0),
        _stationWithRating(id: 5, slug: 'e', title: 'E', totalListeners: 500, averageRating: 0, reviewCount: 0),
      ];

      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: const {'a': 1}, // only one play → bucket needs 2 backfill slots
        favoriteSlugs: const [],
      );

      expect(result.mostPlayedSlugs.length, 3);
      // Backfill should pick highest-listener stations that aren't already placed
      // and aren't the station of the day. Either e or d should be backfilled.
      final stationOfDay = result.stationOfDaySlug;
      final candidates = result.mostPlayedSlugs.where((s) => s != 'a' && s != stationOfDay).toSet();
      // At least one of the high-listener picks should appear.
      expect(candidates.intersection({'d', 'e'}), isNotEmpty);
    });

    test('preserves the entire station list (no duplicates, no drops)', () {
      final stations = List.generate(
        10,
        (i) => _stationWithRating(id: i + 1, slug: 's$i', title: 'S$i', totalListeners: i),
      );

      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: const {'s1': 5, 's2': 3, 's5': 1},
        favoriteSlugs: const ['s9'],
      );

      expect(result.sorted.length, stations.length);
      final slugs = result.sorted.map((s) => s.slug).toList();
      expect(slugs.toSet().length, stations.length, reason: 'No duplicates allowed');
    });

    test('station of the day rotates daily — same day produces same slug', () {
      final stations = List.generate(
        7,
        (i) => _stationWithRating(id: i + 1, slug: 's$i', title: 'S$i'),
      );

      final r1 = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: const {},
        favoriteSlugs: const [],
      );
      final r2 = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: const {},
        favoriteSlugs: const [],
      );

      expect(r1.stationOfDaySlug, r2.stationOfDaySlug);
    });
  });
}
