import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// Tests that next/previous navigation stays within the favorites or the car
/// category the user started playing from.
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

    test('with a single favorite, next and previous go through every '
        'station', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
      ];
      seedStations(stations, ['beta']); // 1 favorite
      service.startedFromFavorites = true;

      expect(service.getNextStation('beta')!.slug, 'gamma');
      expect(service.getPreviousStation('beta')!.slug, 'alpha');
      // Off the favorite, the cycle keeps going instead of jumping back.
      expect(service.getNextStation('gamma')!.slug, 'alpha');
      expect(service.getNextStation('alpha')!.slug, 'beta');
    });

    test('a second favorite brings back the favorites cycle', () {
      // Alphabetical: Alpha, Beta, Delta, Gamma.
      seedStations(fourStations(), ['beta']);
      service.startedFromFavorites = true;
      expect(service.getNextStation('beta')!.slug, 'delta');

      service.favoriteStationSlugs.add(['beta', 'gamma']);

      expect(service.getNextStation('beta')!.slug, 'gamma');
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

    test('full cycle visits every favorite in the listener\'s order, then '
        'wraps', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta'),
        StationFactory.createStation(id: 5, slug: 'epsilon', title: 'Epsilon'),
      ];
      // Arranged by the listener: navigation follows their order, as the
      // Favorite section shows it, not the list's alphabetical sort.
      seedStations(stations, ['gamma', 'epsilon', 'alpha']);
      service.startedFromFavorites = true;

      final visited = <String>['alpha'];
      for (var i = 0; i < 3; i++) {
        visited.add(service.getNextStation(visited.last)!.slug);
      }

      expect(visited, ['alpha', 'gamma', 'epsilon', 'alpha']);
      expect(service.getPreviousStation('gamma')!.slug, 'alpha');
    });

    test('a favorite added mid-session joins the cycle, last', () {
      seedStations(fourStations(), ['alpha', 'gamma']);
      service.startedFromFavorites = true;
      expect(service.getNextStation('alpha')!.slug, 'gamma');

      service.favoriteStationSlugs.add(['alpha', 'gamma', 'beta']);

      expect(service.getNextStation('gamma')!.slug, 'beta');
      expect(service.getNextStation('beta')!.slug, 'alpha');
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
      seedStations(fourStations(), ['beta', 'delta']);
      service.startedFromFavorites = true;

      // Gamma is last: the next favorite wraps around to Beta.
      expect(service.getNextStation('gamma')!.slug, 'beta');
      // Alpha is first: the previous favorite wraps around to Delta.
      expect(service.getPreviousStation('alpha')!.slug, 'delta');
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

    test('with a car connected, a station inside the group navigates the '
        'full catalog the car lists', () {
      final all = fourStations();
      service.stations.add(all);
      // The phone shows Alpha, Delta and Gamma; the car shows all four.
      seedStations([all[0], all[2], all[3]], []);

      expect(service.getNextStation('alpha', wholeCatalog: true)!.slug, 'beta');
      expect(
        service.getPreviousStation('beta', wholeCatalog: true)!.slug,
        'alpha',
      );
    });

    test('with a car connected, favorites cycle every favorite, not only '
        'those in the group', () {
      final all = fourStations();
      service.stations.add(all);
      // The phone shows Alpha and Beta; Delta is a favorite outside it.
      seedStations([all[0], all[1]], ['alpha', 'delta']);
      service.startedFromFavorites = true;

      expect(service.getNextStation('alpha')!.slug, 'beta',
          reason: 'the phone group holds only one favorite, so its stations '
              'are navigated');
      expect(
        service.getNextStation('alpha', wholeCatalog: true)!.slug,
        'delta',
      );
    });
  });

  group('Car category navigation', () {
    /// Seeds the catalog with [fourStations] and a "Copii" group of
    /// [stationIds], as the car's Categories tab lists it.
    void seedCategory(List<int> stationIds) {
      final all = fourStations();
      service.stations.add(all);
      seedStations(all, []);
      service.stationGroups.add([
        StationFactory.createStationGroup(
          id: 1,
          name: 'Copii',
          slug: 'copii',
          stationToStationGroups: [
            for (final id in stationIds)
              StationFactory.createStationToStationGroup(stationId: id),
          ],
        ),
      ]);
    }

    test('defaults to no category', () {
      expect(service.startedFromGroup, isNull);
    });

    test('next and previous cycle through the category in the car order',
        () {
      // Alphabetical: Alpha, Beta, Delta, Gamma. Copii: Alpha, Gamma, Delta.
      seedCategory([1, 3, 4]);
      service.startedFromGroup = 'copii';

      final visited = <String>['alpha'];
      for (var i = 0; i < 3; i++) {
        visited.add(
          service.getNextStation(visited.last, wholeCatalog: true)!.slug,
        );
      }

      expect(visited, ['alpha', 'delta', 'gamma', 'alpha']);
      expect(
        service.getPreviousStation('alpha', wholeCatalog: true)!.slug,
        'gamma',
      );
    });

    test('the category wins over the group the phone shows', () {
      final all = fourStations();
      seedCategory([1, 3]);
      // The phone shows Alpha, Beta and Delta.
      seedStations([all[0], all[1], all[3]], []);
      service.startedFromGroup = 'copii';

      expect(service.getNextStation('alpha')!.slug, 'gamma');
      expect(service.getNextStation('gamma')!.slug, 'alpha');
    });

    test('without a category, next goes through the whole catalog', () {
      seedCategory([1, 3]);
      service.startedFromGroup = 'copii';
      service.startedFromGroup = null;

      expect(service.getNextStation('alpha', wholeCatalog: true)!.slug,
          'beta');
    });

    test('the category wins over the favorites', () {
      seedCategory([1, 3]);
      service.favoriteStationSlugs.add(['alpha', 'beta']);
      service.startedFromFavorites = true;
      service.startedFromGroup = 'copii';

      expect(service.getNextStation('alpha', wholeCatalog: true)!.slug,
          'gamma');
    });

    test('a station that left the category continues from its slot', () {
      // Copii: Alpha, Delta. Beta was playing when it left the group.
      seedCategory([1, 4]);
      service.startedFromGroup = 'copii';

      expect(service.getNextStation('beta', wholeCatalog: true)!.slug,
          'delta');
      expect(service.getPreviousStation('beta', wholeCatalog: true)!.slug,
          'alpha');
    });

    test('a category the API no longer lists falls back to the catalog', () {
      seedCategory([1, 3]);
      service.startedFromGroup = 'colinde';

      expect(service.getNextStation('alpha', wholeCatalog: true)!.slug,
          'beta');
    });

    test('a one-station category navigates the whole catalog', () {
      // Alphabetical: Alpha, Beta, Delta, Gamma. Copii: Gamma.
      seedCategory([3]);
      service.startedFromGroup = 'copii';

      expect(service.getNextStation('gamma', wholeCatalog: true)!.slug,
          'alpha');
      expect(service.getPreviousStation('gamma', wholeCatalog: true)!.slug,
          'delta');
    });

    test('an empty category falls back to the catalog', () {
      seedCategory([]);
      service.startedFromGroup = 'copii';

      expect(service.getNextStation('alpha', wholeCatalog: true)!.slug,
          'beta');
    });

    test('the category survives an app restart', () {
      service.startedFromGroup = 'copii';

      expect(newService().startedFromGroup, 'copii');
      final prefs = GetIt.instance<SharedPreferences>();
      expect(prefs.getString('started_from_group'), 'copii');

      service.startedFromGroup = null;
      expect(prefs.containsKey('started_from_group'), isFalse);
    });
  });

  group('Favorite navigation - edge cases', () {
    test('empty station list returns null', () {
      seedStations([], ['alpha']);
      service.startedFromFavorites = true;

      expect(service.getNextStation('alpha'), isNull);
      expect(service.getPreviousStation('alpha'), isNull);
    });

    test('current station not in any list returns the first or the last '
        'favorite', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
      ];
      seedStations(stations, ['beta', 'gamma']);
      service.startedFromFavorites = true;

      expect(service.getNextStation('nonexistent')!.slug, 'beta');
      expect(service.getPreviousStation('nonexistent')!.slug, 'gamma');
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
