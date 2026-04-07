import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// Tests that next/previous navigation prioritizes favorites when
/// the user started playing from the favorites list.
void main() {
  late StationDataService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // Use alphabetical sort so station order is predictable
      'station_sort_preference': 'alphabetical',
    });
    final prefs = await SharedPreferences.getInstance();

    final getIt = GetIt.instance;
    getIt.reset();
    getIt.registerSingleton<SharedPreferences>(prefs);
    getIt.registerSingleton<PlayCountService>(PlayCountService());

    // Create a StationDataService with a dummy graphqlClient
    // (we won't use network features in these tests)
    service = StationDataService(
      graphqlClient: GraphQLClient(
        link: HttpLink('https://example.com/graphql'),
        cache: GraphQLCache(),
      ),
    );
  });

  tearDown(() {
    GetIt.instance.reset();
  });

  /// Helper: seeds filteredStations and favoriteStationSlugs directly.
  void seedStations(List<Station> stations, List<String> favoriteSlugs) {
    service.filteredStations.add(stations);
    service.favoriteStationSlugs.add(favoriteSlugs);
  }

  group('Favorite navigation - startedFromFavorites=false (default)', () {
    test('next follows alphabetical order through all stations', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta'),
      ];
      seedStations(stations, ['alpha', 'gamma']); // 2 favorites
      service.startedFromFavorites = false;

      // Alphabetical sort: Alpha, Beta, Delta, Gamma
      final next1 = service.getNextStation('alpha');
      expect(next1!.slug, 'beta');

      final next2 = service.getNextStation('beta');
      expect(next2!.slug, 'delta');

      final next3 = service.getNextStation('delta');
      expect(next3!.slug, 'gamma');

      // Wraps around
      final next4 = service.getNextStation('gamma');
      expect(next4!.slug, 'alpha');
    });
  });

  group('Favorite navigation - startedFromFavorites=true', () {
    test('next cycles through favorites first, then others', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta'),
      ];
      seedStations(stations, ['alpha', 'gamma']); // 2 favorites
      service.startedFromFavorites = true;

      // Alphabetical sort: Alpha, Beta, Delta, Gamma
      // Navigation playlist: [Alpha, Gamma] (favorites sorted) + [Beta, Delta] (others sorted)
      final next1 = service.getNextStation('alpha');
      expect(next1!.slug, 'gamma', reason: 'Should go to next favorite');

      final next2 = service.getNextStation('gamma');
      expect(next2!.slug, 'beta', reason: 'Should continue to non-favorites after favorites');

      final next3 = service.getNextStation('beta');
      expect(next3!.slug, 'delta');

      // Wraps around to first favorite
      final next4 = service.getNextStation('delta');
      expect(next4!.slug, 'alpha', reason: 'Should wrap back to first favorite');
    });

    test('previous cycles through favorites first (reverse), then others', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta'),
      ];
      seedStations(stations, ['alpha', 'gamma']); // 2 favorites
      service.startedFromFavorites = true;

      // Navigation playlist: [Alpha, Gamma, Beta, Delta]
      // Previous from Alpha wraps to end
      final prev1 = service.getPreviousStation('alpha');
      expect(prev1!.slug, 'delta', reason: 'Should wrap to last station');

      final prev2 = service.getPreviousStation('gamma');
      expect(prev2!.slug, 'alpha', reason: 'Should go to previous favorite');

      final prev3 = service.getPreviousStation('beta');
      expect(prev3!.slug, 'gamma', reason: 'Should go from non-fav to last favorite');
    });

    test('with single favorite, next goes to non-favorites then back', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
      ];
      seedStations(stations, ['beta']); // 1 favorite
      service.startedFromFavorites = true;

      // Navigation playlist: [Beta] + [Alpha, Gamma]
      final next1 = service.getNextStation('beta');
      expect(next1!.slug, 'alpha', reason: 'After sole favorite, go to first non-favorite');

      final next2 = service.getNextStation('alpha');
      expect(next2!.slug, 'gamma');

      final next3 = service.getNextStation('gamma');
      expect(next3!.slug, 'beta', reason: 'Wraps back to the favorite');
    });

    test('with all stations as favorites, just cycles through favorites', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
      ];
      seedStations(stations, ['alpha', 'beta', 'gamma']); // all favorites
      service.startedFromFavorites = true;

      // All stations are favorites, so playlist = all favorites sorted
      final next1 = service.getNextStation('alpha');
      expect(next1!.slug, 'beta');

      final next2 = service.getNextStation('beta');
      expect(next2!.slug, 'gamma');

      final next3 = service.getNextStation('gamma');
      expect(next3!.slug, 'alpha');
    });

    test('with no favorites, falls through to full sorted list', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
      ];
      seedStations(stations, []); // no favorites
      service.startedFromFavorites = true;

      final next = service.getNextStation('alpha');
      expect(next!.slug, 'beta');
    });

    test('full cycle: favorites first, then rest, then wrap', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta'),
        StationFactory.createStation(id: 5, slug: 'epsilon', title: 'Epsilon'),
      ];
      seedStations(stations, ['gamma', 'alpha']); // 2 favorites (Gamma and Alpha)
      service.startedFromFavorites = true;

      // Alphabetical: Alpha, Beta, Delta, Epsilon, Gamma
      // Favorites (sorted): Alpha, Gamma
      // Others (sorted): Beta, Delta, Epsilon
      // Navigation: [Alpha, Gamma, Beta, Delta, Epsilon]

      final visited = <String>[];
      String current = 'alpha';
      visited.add(current);
      for (int i = 0; i < 4; i++) {
        current = service.getNextStation(current)!.slug;
        visited.add(current);
      }

      expect(visited, ['alpha', 'gamma', 'beta', 'delta', 'epsilon']);

      // One more wraps back
      final wrap = service.getNextStation('epsilon');
      expect(wrap!.slug, 'alpha');
    });
  });

  group('Favorite navigation - context switching', () {
    test('switching from favorites to all-stations resets navigation', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
      ];
      seedStations(stations, ['alpha', 'gamma']);

      // Start from favorites
      service.startedFromFavorites = true;
      final next1 = service.getNextStation('alpha');
      expect(next1!.slug, 'gamma', reason: 'Favorites first');

      // User selects a station from all-stations list
      service.startedFromFavorites = false;
      final next2 = service.getNextStation('alpha');
      expect(next2!.slug, 'beta', reason: 'Normal alphabetical order');
    });

    test('starting from all-stations, then switching to favorites', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
      ];
      seedStations(stations, ['alpha', 'gamma']);

      // Start from all stations
      service.startedFromFavorites = false;
      final next1 = service.getNextStation('alpha');
      expect(next1!.slug, 'beta');

      // User switches to favorites
      service.startedFromFavorites = true;
      final next2 = service.getNextStation('alpha');
      expect(next2!.slug, 'gamma', reason: 'Now favorites-first');
    });
  });

  group('Favorite navigation - edge cases', () {
    test('empty station list returns null', () {
      seedStations([], ['alpha']);
      service.startedFromFavorites = true;

      expect(service.getNextStation('alpha'), isNull);
      expect(service.getPreviousStation('alpha'), isNull);
    });

    test('current station not in playlist returns first', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
      ];
      seedStations(stations, ['alpha']);
      service.startedFromFavorites = true;

      // Station not in list — getNextStation returns first in playlist
      final next = service.getNextStation('nonexistent');
      expect(next!.slug, 'alpha', reason: 'First station in favorites-first playlist');
    });

    test('favorite slug not matching any station is ignored', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
      ];
      // 'nonexistent' is in favorites but not in station list
      seedStations(stations, ['alpha', 'nonexistent']);
      service.startedFromFavorites = true;

      // Only Alpha is a real favorite, so navigation: [Alpha, Beta]
      final next = service.getNextStation('alpha');
      expect(next!.slug, 'beta');
    });

    test('round-trip: next then previous returns to same station', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta'),
      ];
      seedStations(stations, ['alpha', 'gamma']);
      service.startedFromFavorites = true;

      // Navigate forward
      final next = service.getNextStation('alpha');
      expect(next!.slug, 'gamma');

      // Navigate back
      final prev = service.getPreviousStation('gamma');
      expect(prev!.slug, 'alpha', reason: 'Round-trip returns to original');
    });
  });
}
