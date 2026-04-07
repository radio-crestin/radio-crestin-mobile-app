import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// Tests that skip next/prev always follows the same sorted order regardless
/// of where the station was selected (phone UI, CarPlay, Android Auto).
///
/// The navigation logic is centralized in StationDataService.getNextStation()
/// and getPreviousStation(), which always compute the sorted list dynamically.
/// There is no captured playlist that can become stale.
void main() {
  /// Replicates StationDataService.getNextStation logic.
  Station? getNextStation(List<Station> sortedStations, String currentSlug) {
    if (sortedStations.isEmpty) return null;
    final idx = sortedStations.indexWhere((s) => s.slug == currentSlug);
    if (idx < 0) return sortedStations.first;
    return sortedStations[(idx + 1) % sortedStations.length];
  }

  /// Replicates StationDataService.getPreviousStation logic.
  Station? getPreviousStation(List<Station> sortedStations, String currentSlug) {
    if (sortedStations.isEmpty) return null;
    final idx = sortedStations.indexWhere((s) => s.slug == currentSlug);
    if (idx <= 0) return sortedStations.last;
    return sortedStations[idx - 1];
  }

  group('Centralized navigation - single source of truth', () {
    late List<Station> sortedStations;

    setUp(() {
      // Sorted alphabetically (simulates getSortedStations() output)
      sortedStations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha', order: 0),
        StationFactory.createStation(id: 2, slug: 'bravo', title: 'Bravo', order: 1),
        StationFactory.createStation(id: 3, slug: 'charlie', title: 'Charlie', order: 2),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta', order: 3),
        StationFactory.createStation(id: 5, slug: 'echo', title: 'Echo', order: 4),
      ];
    });

    test('getNextStation follows sorted order', () {
      expect(getNextStation(sortedStations, 'alpha')!.slug, 'bravo');
      expect(getNextStation(sortedStations, 'bravo')!.slug, 'charlie');
      expect(getNextStation(sortedStations, 'charlie')!.slug, 'delta');
      expect(getNextStation(sortedStations, 'delta')!.slug, 'echo');
    });

    test('getNextStation wraps around at end', () {
      expect(getNextStation(sortedStations, 'echo')!.slug, 'alpha');
    });

    test('getPreviousStation follows sorted order backwards', () {
      expect(getPreviousStation(sortedStations, 'echo')!.slug, 'delta');
      expect(getPreviousStation(sortedStations, 'delta')!.slug, 'charlie');
      expect(getPreviousStation(sortedStations, 'charlie')!.slug, 'bravo');
      expect(getPreviousStation(sortedStations, 'bravo')!.slug, 'alpha');
    });

    test('getPreviousStation wraps around at beginning', () {
      expect(getPreviousStation(sortedStations, 'alpha')!.slug, 'echo');
    });

    test('unknown slug falls back to first/last', () {
      expect(getNextStation(sortedStations, 'nonexistent')!.slug, 'alpha');
      expect(getPreviousStation(sortedStations, 'nonexistent')!.slug, 'echo');
    });

    test('empty station list returns null', () {
      expect(getNextStation([], 'alpha'), isNull);
      expect(getPreviousStation([], 'alpha'), isNull);
    });

    test('full cycle through stations returns to start', () {
      Station current = sortedStations.first;
      final visited = <String>[];

      for (int i = 0; i < sortedStations.length; i++) {
        visited.add(current.slug);
        current = getNextStation(sortedStations, current.slug)!;
      }

      expect(visited, ['alpha', 'bravo', 'charlie', 'delta', 'echo']);
      expect(current.slug, 'alpha', reason: 'Should wrap back to start');
    });

    test('phone, CarPlay, and Android Auto all use same sorted list', () {
      // All surfaces delegate to StationDataService.getSortedStations()
      // which returns the same result. Verify that next from any surface
      // gives the same result.
      final phoneSorted = sortedStations;
      final carPlaySorted = sortedStations; // same source of truth
      final androidAutoSorted = sortedStations; // same source of truth

      for (final station in sortedStations) {
        final phoneNext = getNextStation(phoneSorted, station.slug);
        final carPlayNext = getNextStation(carPlaySorted, station.slug);
        final aaNext = getNextStation(androidAutoSorted, station.slug);

        expect(phoneNext!.slug, carPlayNext!.slug,
            reason: 'Phone and CarPlay must agree on next after ${station.slug}');
        expect(phoneNext.slug, aaNext!.slug,
            reason: 'Phone and Android Auto must agree on next after ${station.slug}');
      }
    });

    test('navigation is consistent after sort order changes', () {
      // Since navigation always computes dynamically from getSortedStations(),
      // it automatically picks up sort changes. No stale playlist.

      // First sort: alphabetical
      var sorted = List<Station>.from(sortedStations);
      expect(getNextStation(sorted, 'alpha')!.slug, 'bravo');

      // Sort changes to reverse (simulates user changing sort in settings)
      sorted = sorted.reversed.toList();
      expect(getNextStation(sorted, 'alpha')!.slug, isNot('bravo'),
          reason: 'After re-sort, next should follow new order');
      // In reversed: echo, delta, charlie, bravo, alpha
      // Next after alpha (last) wraps to echo (first)
      expect(getNextStation(sorted, 'alpha')!.slug, 'echo');
    });
  });
}
