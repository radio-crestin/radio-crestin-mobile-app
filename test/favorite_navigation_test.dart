import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// Tests that next/previous navigation stays within the favorites when the
/// user started playing from a favorites list.
void main() {
  late StationDataService service;

  StationDataService newService() => StationDataService(
        graphqlClient: GraphQLClient(
          link: HttpLink('https://example.com/graphql'),
          cache: GraphQLCache(),
        ),
      );

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

    // A dummy graphqlClient: these tests don't use network features.
    service = newService();
  });

  tearDown(() {
    GetIt.instance.reset();
  });

  /// Helper: seeds filteredStations and favoriteStationSlugs directly.
  void seedStations(List<Station> stations, List<String> favoriteSlugs) {
    service.filteredStations.add(stations);
    service.favoriteStationSlugs.add(favoriteSlugs);
  }

  List<Station> fourStations() => [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta'),
      ];

  group('Favorite navigation - startedFromFavorites=false (default)', () {
    test('defaults to false', () {
      expect(service.startedFromFavorites, isFalse);
    });

    test('next follows alphabetical order through all stations', () {
      seedStations(fourStations(), ['alpha', 'gamma']); // 2 favorites
      service.startedFromFavorites = false;

      // Alphabetical sort: Alpha, Beta, Delta, Gamma
      expect(service.getNextStation('alpha')!.slug, 'beta');
      expect(service.getNextStation('beta')!.slug, 'delta');
      expect(service.getNextStation('delta')!.slug, 'gamma');
      // Wraps around
      expect(service.getNextStation('gamma')!.slug, 'alpha');
    });
  });

  group('Favorite navigation - startedFromFavorites=true', () {
    test('next cycles through the favorites only', () {
      seedStations(fourStations(), ['alpha', 'gamma']); // 2 favorites
      service.startedFromFavorites = true;

      // Alphabetical sort: Alpha, Beta, Delta, Gamma
      // Navigation playlist: [Alpha, Gamma]
      expect(service.getNextStation('alpha')!.slug, 'gamma',
          reason: 'Should go to next favorite');
      expect(service.getNextStation('gamma')!.slug, 'alpha',
          reason: 'Should wrap back to the first favorite, '
              'never reaching a non-favorite');
    });

    test('previous cycles through the favorites only (reverse)', () {
      seedStations(fourStations(), ['alpha', 'gamma']); // 2 favorites
      service.startedFromFavorites = true;

      expect(service.getPreviousStation('alpha')!.slug, 'gamma',
          reason: 'Should wrap to the last favorite');
      expect(service.getPreviousStation('gamma')!.slug, 'alpha',
          reason: 'Should go to previous favorite');
    });

    test('with a single favorite, next and previous stay on it', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
      ];
      seedStations(stations, ['beta']); // 1 favorite
      service.startedFromFavorites = true;

      expect(service.getNextStation('beta')!.slug, 'beta');
      expect(service.getPreviousStation('beta')!.slug, 'beta');
    });

    test('with all stations as favorites, just cycles through favorites', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
      ];
      seedStations(stations, ['alpha', 'beta', 'gamma']); // all favorites
      service.startedFromFavorites = true;

      expect(service.getNextStation('alpha')!.slug, 'beta');
      expect(service.getNextStation('beta')!.slug, 'gamma');
      expect(service.getNextStation('gamma')!.slug, 'alpha');
    });

    test('with no favorites, falls through to full sorted list', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
      ];
      seedStations(stations, []); // no favorites
      service.startedFromFavorites = true;

      expect(service.getNextStation('alpha')!.slug, 'beta');
    });

    test('full cycle visits every favorite in sorted order, then wraps', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta'),
        StationFactory.createStation(id: 5, slug: 'epsilon', title: 'Epsilon'),
      ];
      // Favorites saved out of order: navigation follows the sort order.
      seedStations(stations, ['gamma', 'epsilon', 'alpha']);
      service.startedFromFavorites = true;

      // Alphabetical: Alpha, Beta, Delta, Epsilon, Gamma
      // Navigation: [Alpha, Epsilon, Gamma]
      final visited = <String>['alpha'];
      for (var i = 0; i < 3; i++) {
        visited.add(service.getNextStation(visited.last)!.slug);
      }

      expect(visited, ['alpha', 'epsilon', 'gamma', 'alpha']);
    });

    test('a favorite added mid-session joins the cycle', () {
      seedStations(fourStations(), ['alpha', 'gamma']);
      service.startedFromFavorites = true;
      expect(service.getNextStation('alpha')!.slug, 'gamma');

      service.favoriteStationSlugs.add(['alpha', 'gamma', 'beta']);

      expect(service.getNextStation('alpha')!.slug, 'beta');
    });
  });

  group('Favorite navigation - current station removed from favorites', () {
    test('next goes to the following favorite in sorted order', () {
      // Alphabetical: Alpha, Beta, Delta, Gamma. Playing Beta, which the
      // user just removed from favorites.
      seedStations(fourStations(), ['alpha', 'gamma']);
      service.startedFromFavorites = true;

      expect(service.getNextStation('beta')!.slug, 'gamma');
    });

    test('previous goes to the preceding favorite in sorted order', () {
      seedStations(fourStations(), ['alpha', 'gamma']);
      service.startedFromFavorites = true;

      expect(service.getPreviousStation('delta')!.slug, 'alpha');
    });

    test('wraps around the sorted order to find a favorite', () {
      seedStations(fourStations(), ['beta']);
      service.startedFromFavorites = true;

      // Gamma is last: the next favorite wraps around to Beta.
      expect(service.getNextStation('gamma')!.slug, 'beta');
      // Alpha is first: the previous favorite wraps around to Beta.
      expect(service.getPreviousStation('alpha')!.slug, 'beta');
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
      expect(service.getNextStation('alpha')!.slug, 'gamma',
          reason: 'Favorites only');

      // User selects a station from all-stations list
      service.startedFromFavorites = false;
      expect(service.getNextStation('alpha')!.slug, 'beta',
          reason: 'Normal alphabetical order');
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
      expect(service.getNextStation('alpha')!.slug, 'beta');

      // User switches to favorites
      service.startedFromFavorites = true;
      expect(service.getNextStation('alpha')!.slug, 'gamma',
          reason: 'Now favorites only');
    });

    test('the context survives an app restart', () {
      service.startedFromFavorites = true;

      final restarted = newService();

      expect(restarted.startedFromFavorites, isTrue);
      final prefs = GetIt.instance<SharedPreferences>();
      expect(prefs.getBool('started_from_favorites'), isTrue);
    });
  });

  group('Favorite navigation - station group filter', () {
    test('a station inside the selected group navigates the group', () {
      final all = fourStations();
      service.stations.add(all);
      // Group shows Alpha, Delta, Gamma (Beta is filtered out).
      seedStations([all[0], all[2], all[3]], []);

      expect(service.getNextStation('alpha')!.slug, 'delta');
    });

    test('a station outside the selected group navigates the full catalog',
        () {
      final all = fourStations();
      service.stations.add(all);
      // Group shows Alpha and Gamma; Beta was picked from the car or search.
      seedStations([all[0], all[2]], []);

      expect(service.getNextStation('beta')!.slug, 'delta');
      expect(service.getPreviousStation('beta')!.slug, 'alpha');
    });

    test('a favorite outside the selected group cycles all favorites', () {
      final all = fourStations();
      service.stations.add(all);
      // Group shows Alpha only; Beta and Delta are favorites outside it.
      seedStations([all[0]], ['beta', 'delta']);
      service.startedFromFavorites = true;

      expect(service.getNextStation('beta')!.slug, 'delta');
      expect(service.getNextStation('delta')!.slug, 'beta');
    });
  });

  group('Favorite navigation - edge cases', () {
    test('empty station list returns null', () {
      seedStations([], ['alpha']);
      service.startedFromFavorites = true;

      expect(service.getNextStation('alpha'), isNull);
      expect(service.getPreviousStation('alpha'), isNull);
    });

    test('current station not in any list returns the first favorite', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
      ];
      seedStations(stations, ['beta']);
      service.startedFromFavorites = true;

      expect(service.getNextStation('nonexistent')!.slug, 'beta');
      expect(service.getPreviousStation('nonexistent')!.slug, 'beta');
    });

    test('favorite slug not matching any station is ignored', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
      ];
      // 'nonexistent' is in favorites but not in station list
      seedStations(stations, ['alpha', 'nonexistent', 'gamma']);
      service.startedFromFavorites = true;

      // Only Alpha and Gamma are real favorites: navigation [Alpha, Gamma]
      expect(service.getNextStation('alpha')!.slug, 'gamma');
      expect(service.getNextStation('gamma')!.slug, 'alpha');
    });

    test('round-trip: next then previous returns to same station', () {
      seedStations(fourStations(), ['alpha', 'gamma']);
      service.startedFromFavorites = true;

      final next = service.getNextStation('alpha');
      expect(next!.slug, 'gamma');

      final prev = service.getPreviousStation(next.slug);
      expect(prev!.slug, 'alpha', reason: 'Round-trip returns to original');
    });
  });
}
