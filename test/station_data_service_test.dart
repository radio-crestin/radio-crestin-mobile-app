import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

// Notes for future contributors:
// - Avoid calling `service.initialize()` in unit tests. It kicks off
//   `_setupRefreshStations()` which spawns un-awaited network calls
//   (graphql + REST) that survive the test boundary and trip the
//   "test failed after it had already completed" detector.
// - Drive state directly via the public BehaviorSubjects
//   (`stations`, `filteredStations`, `favoriteStationSlugs`) and call
//   public methods on the service. That covers the contract surface
//   without requiring a live network or initialize().

StationDataService _newService() => StationDataService(
      graphqlClient: GraphQLClient(
        link: HttpLink('https://example.com/graphql'),
        cache: GraphQLCache(),
      ),
    );

List<Station> _stations() => [
      StationFactory.createStation(id: 1, slug: 'a', title: 'A', totalListeners: 100),
      StationFactory.createStation(id: 2, slug: 'b', title: 'B', totalListeners: 50),
      StationFactory.createStation(id: 3, slug: 'c', title: 'C', totalListeners: 200),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StationDataService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'station_sort_preference': 'alphabetical',
    });
    final prefs = await SharedPreferences.getInstance();
    GetIt.instance.reset();
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
    GetIt.instance.registerSingleton<PlayCountService>(PlayCountService());
    service = _newService();
  });

  tearDown(() {
    service.dispose();
    GetIt.instance.reset();
  });

  group('Favorites', () {
    test('setStationIsFavorite(true) appends slug and persists', () async {
      final station = _stations().first;

      await service.setStationIsFavorite(station, true);

      expect(service.favoriteStationSlugs.value, contains(station.slug));
      final prefs = GetIt.instance<SharedPreferences>();
      final stored = json.decode(prefs.getString('favoriteStationSlugs')!) as List;
      expect(stored, contains(station.slug));
    });

    test('setStationIsFavorite(false) removes slug and persists', () async {
      final prefs = GetIt.instance<SharedPreferences>();
      final station = _stations().first;
      await service.setStationIsFavorite(station, true);
      await service.setStationIsFavorite(station, false);

      expect(service.favoriteStationSlugs.value, isNot(contains(station.slug)));
      final stored = json.decode(prefs.getString('favoriteStationSlugs')!) as List;
      expect(stored, isNot(contains(station.slug)));
    });

    test('toggling the same favorite twice appends — current behavior', () async {
      // The service does NOT de-dup. If you change that contract, update
      // this test along with whatever feature ride-alongs (favorites tab,
      // CarPlay favorite list) depended on the duplicate.
      final station = _stations().first;
      await service.setStationIsFavorite(station, true);
      await service.setStationIsFavorite(station, true);

      expect(
        service.favoriteStationSlugs.value.where((s) => s == station.slug).length,
        2,
      );
    });

    test('favoriteStationSlugs starts empty (seeded with [])', () {
      expect(service.favoriteStationSlugs.value, isEmpty);
    });
  });

  group('Polling lifecycle', () {
    test('pausePolling without prior resume is a no-op', () {
      expect(() => service.pausePolling(), returnsNormally);
    });

    test('resumePolling then pausePolling cleans up', () {
      service.resumePolling();
      expect(() => service.pausePolling(), returnsNormally);
    });

    test('resumePolling is idempotent — second call is a no-op', () {
      service.resumePolling();
      expect(() => service.resumePolling(), returnsNormally);
      service.pausePolling();
    });

    test('dispose cancels timers cleanly and is idempotent', () {
      service.resumePolling();
      expect(() => service.dispose(), returnsNormally);
      expect(() => service.dispose(), returnsNormally);
    });
  });

  group('invalidateSortCache', () {
    test('emits on the sortOrderChanged stream', () async {
      var emissions = 0;
      final sub = service.sortOrderChanged.stream.listen((_) => emissions++);

      service.invalidateSortCache();
      service.invalidateSortCache();
      await Future<void>.delayed(Duration.zero);

      expect(emissions, 2);
      await sub.cancel();
    });
  });

  group('Navigation — getNextStation / getPreviousStation', () {
    setUp(() {
      service.filteredStations.add(_stations());
      service.favoriteStationSlugs.add([]);
      // Cache the order via a sort.
      service.getSortedStations();
    });

    test('next moves forward through the cached sort order', () {
      // Alphabetical: a, b, c
      expect(service.getNextStation('a')?.slug, 'b');
      expect(service.getNextStation('b')?.slug, 'c');
    });

    test('next wraps around at the end', () {
      expect(service.getNextStation('c')?.slug, 'a');
    });

    test('previous moves backward through the cached sort order', () {
      expect(service.getPreviousStation('c')?.slug, 'b');
      expect(service.getPreviousStation('b')?.slug, 'a');
    });

    test('previous wraps to the last station from the first', () {
      expect(service.getPreviousStation('a')?.slug, 'c');
    });

    test('next returns the first station for an unknown slug', () {
      expect(service.getNextStation('not-a-slug')?.slug, 'a');
    });

    test('previous returns the last station for an unknown slug (idx <= 0)', () {
      expect(service.getPreviousStation('not-a-slug')?.slug, 'c');
    });

    test('returns null when the playlist is empty', () {
      service.filteredStations.add(<Station>[]);
      service.invalidateSortCache();
      expect(service.getNextStation('anything'), isNull);
      expect(service.getPreviousStation('anything'), isNull);
    });

    test('startedFromFavorites=true reorders playlist with favorites first', () {
      // Favorites: ['c']. Sorted: [a, b, c]. Reordered playlist: [c, a, b].
      service.favoriteStationSlugs.add(['c']);
      service.startedFromFavorites = true;

      // From 'c' (idx 0) → 'a' (idx 1).
      expect(service.getNextStation('c')?.slug, 'a');
      // From 'a' (idx 1) → previous is 'c' (idx 0).
      expect(service.getPreviousStation('a')?.slug, 'c');
      // From 'b' (idx 2) wraps next → 'c' (idx 0).
      expect(service.getNextStation('b')?.slug, 'c');
    });

    test('startedFromFavorites with no favorites falls back to sorted list', () {
      service.startedFromFavorites = true;
      service.favoriteStationSlugs.add(<String>[]);
      expect(service.getNextStation('a')?.slug, 'b');
    });
  });

  group('getSortedStations cache', () {
    test('returns empty list immediately when filteredStations is empty', () {
      service.filteredStations.add(<Station>[]);
      expect(service.getSortedStations(), isEmpty);
    });

    test('returns the same order on repeated calls (cache hit)', () {
      service.filteredStations.add(_stations());
      service.favoriteStationSlugs.add([]);
      final a = service.getSortedStations().map((s) => s.slug).toList();
      final b = service.getSortedStations().map((s) => s.slug).toList();
      expect(a, b);
    });

    test('appends new stations and re-sorts when count changes', () {
      service.filteredStations.add(_stations());
      service.favoriteStationSlugs.add([]);
      service.getSortedStations(); // populate cache

      final more = [
        ..._stations(),
        StationFactory.createStation(
            id: 99, slug: 'd', title: 'D', totalListeners: 1),
      ];
      service.filteredStations.add(more);

      final result = service.getSortedStations().map((s) => s.slug).toList();
      expect(result, containsAll(['a', 'b', 'c', 'd']));
      expect(result.length, 4);
    });

    test('respects the saved sort option (alphabetical by default in setUp)', () {
      service.filteredStations.add([
        StationFactory.createStation(id: 1, slug: 'z', title: 'Z'),
        StationFactory.createStation(id: 2, slug: 'a', title: 'A'),
        StationFactory.createStation(id: 3, slug: 'm', title: 'M'),
      ]);
      service.favoriteStationSlugs.add([]);

      expect(
        service.getSortedStations().map((s) => s.slug).toList(),
        ['a', 'm', 'z'],
      );
    });
  });
}
