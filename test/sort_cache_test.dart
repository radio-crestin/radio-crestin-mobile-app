import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// Tests that getSortedStations() caches the sort order and only re-sorts
/// on manual refresh (invalidateSortCache) or sort option change.
void main() {
  late StationDataService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'station_sort_preference': 'alphabetical',
    });
    final prefs = await SharedPreferences.getInstance();

    final getIt = GetIt.instance;
    getIt.reset();
    getIt.registerSingleton<SharedPreferences>(prefs);
    getIt.registerSingleton<PlayCountService>(PlayCountService());

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

  List<Station> makeStations() {
    return [
      StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha', totalListeners: 100),
      StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta', totalListeners: 50),
      StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma', totalListeners: 200),
    ];
  }

  group('Sort cache - order stability', () {
    test('sort order stays stable when station metadata changes', () {
      service.filteredStations.add(makeStations());
      service.favoriteStationSlugs.add([]);

      final firstSort = service.getSortedStations();
      final firstOrder = firstSort.map((s) => s.slug).toList();
      // Alphabetical: Alpha, Beta, Gamma
      expect(firstOrder, ['alpha', 'beta', 'gamma']);

      // Simulate a poll updating listeners (metadata change)
      final updatedStations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha', totalListeners: 5),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta', totalListeners: 999),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma', totalListeners: 1),
      ];
      service.filteredStations.add(updatedStations);

      final secondSort = service.getSortedStations();
      final secondOrder = secondSort.map((s) => s.slug).toList();
      // Order should be the same despite different listeners
      expect(secondOrder, firstOrder, reason: 'Sort order should stay cached');

      // But metadata should be fresh
      final beta = secondSort.firstWhere((s) => s.slug == 'beta');
      expect(beta.totalListeners, 999, reason: 'Station metadata should be fresh');
    });

    test('invalidateSortCache forces a re-sort', () {
      service.filteredStations.add(makeStations());
      service.favoriteStationSlugs.add([]);

      final firstSort = service.getSortedStations();
      expect(firstSort.map((s) => s.slug).toList(), ['alpha', 'beta', 'gamma']);

      // Invalidate cache
      service.invalidateSortCache();

      // Same stations, same sort option — order should be the same
      final secondSort = service.getSortedStations();
      expect(secondSort.map((s) => s.slug).toList(), ['alpha', 'beta', 'gamma']);
    });

    test('sort option change invalidates cache via station count change detection', () async {
      service.filteredStations.add(makeStations());
      service.favoriteStationSlugs.add([]);

      // First sort with alphabetical
      final firstSort = service.getSortedStations();
      expect(firstSort.map((s) => s.slug).toList(), ['alpha', 'beta', 'gamma']);

      // Change sort option to listeners
      final prefs = GetIt.instance<SharedPreferences>();
      await prefs.setString('station_sort_preference', 'listeners');

      // Cache detects sort option mismatch → re-sorts
      final secondSort = service.getSortedStations();
      final secondOrder = secondSort.map((s) => s.slug).toList();
      // By listeners (desc): Gamma(200), Alpha(100), Beta(50)
      expect(secondOrder, ['gamma', 'alpha', 'beta']);
    });

    test('adding a new station invalidates cache (station count changes)', () {
      service.filteredStations.add(makeStations());
      service.favoriteStationSlugs.add([]);

      service.getSortedStations(); // populate cache

      // Add a new station
      final moreStations = [
        ...makeStations(),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta', totalListeners: 75),
      ];
      service.filteredStations.add(moreStations);

      final sorted = service.getSortedStations();
      // Cache invalidated due to count change — full re-sort
      expect(sorted.length, 4);
      expect(sorted.map((s) => s.slug).toList(), ['alpha', 'beta', 'delta', 'gamma']);
    });

    test('removing a station invalidates cache (station count changes)', () {
      service.filteredStations.add(makeStations());
      service.favoriteStationSlugs.add([]);

      service.getSortedStations(); // populate cache

      // Remove a station
      final fewerStations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha', totalListeners: 100),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma', totalListeners: 200),
      ];
      service.filteredStations.add(fewerStations);

      final sorted = service.getSortedStations();
      expect(sorted.length, 2);
      expect(sorted.map((s) => s.slug).toList(), ['alpha', 'gamma']);
    });
  });

  group('Sort cache - sortOrderChanged stream', () {
    test('invalidateSortCache emits on sortOrderChanged', () async {
      bool emitted = false;
      service.sortOrderChanged.stream.listen((_) {
        emitted = true;
      });

      service.invalidateSortCache();
      await Future.delayed(Duration.zero); // Let stream propagate

      expect(emitted, true);
    });

    test('refreshStations invalidates sort cache', () async {
      // We can't fully test refreshStations (needs GraphQL),
      // but we can verify the cache is cleared
      service.filteredStations.add(makeStations());
      service.favoriteStationSlugs.add([]);

      service.getSortedStations(); // populate cache

      bool emitted = false;
      service.sortOrderChanged.stream.listen((_) {
        emitted = true;
      });

      // refreshStations calls invalidateSortCache internally
      // We can't await the full method (needs network), but
      // the cache invalidation happens synchronously at the start
      try {
        await service.refreshStations().timeout(const Duration(milliseconds: 100));
      } catch (_) {
        // Expected: network call will fail/timeout in test
      }

      await Future.delayed(Duration.zero);
      expect(emitted, true, reason: 'refreshStations should emit sortOrderChanged');
    });
  });

  group('Sort cache - navigation uses cached order', () {
    test('next/previous use cached sort order even after metadata changes', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha', totalListeners: 100),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta', totalListeners: 50),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma', totalListeners: 200),
      ];
      service.filteredStations.add(stations);
      service.favoriteStationSlugs.add([]);

      // First call caches: Alpha, Beta, Gamma
      service.getSortedStations();

      // Simulate poll changing listeners
      final updatedStations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha', totalListeners: 1),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta', totalListeners: 1000),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma', totalListeners: 1),
      ];
      service.filteredStations.add(updatedStations);

      // Navigation should use cached order
      final next = service.getNextStation('alpha');
      expect(next!.slug, 'beta', reason: 'Cached order: alpha → beta');

      final next2 = service.getNextStation('beta');
      expect(next2!.slug, 'gamma', reason: 'Cached order: beta → gamma');
    });
  });
}
