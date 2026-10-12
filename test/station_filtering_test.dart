import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';

import 'helpers/station_factory.dart';

void main() {
  group('Station filtering logic', () {
    late BehaviorSubject<Query$GetStations$station_groups?> selectedStationGroup;
    late BehaviorSubject<List<Station>> stations;
    late BehaviorSubject<List<Station>> filteredStations;

    /// Mirrors the wiring of StationDataService._initFilteredStationsStream,
    /// using the production combiner.
    void setupFilteredStationsStream() {
      final combinedStream = Rx.combineLatest2<
          Query$GetStations$station_groups?, List<Station>, List<Station>>(
        selectedStationGroup.stream,
        stations.stream,
        StationDataService.filterByGroup,
      );

      combinedStream.listen((filteredStationsList) {
        filteredStations.add(filteredStationsList);
      });
    }

    setUp(() {
      selectedStationGroup = BehaviorSubject.seeded(null);
      stations = BehaviorSubject.seeded(<Station>[]);
      filteredStations = BehaviorSubject.seeded(<Station>[]);
    });

    tearDown(() {
      selectedStationGroup.close();
      stations.close();
      filteredStations.close();
    });

    test('returns all stations when no group is selected', () async {
      setupFilteredStationsStream();

      final testStations = StationFactory.createPlaylist(count: 5);
      stations.add(testStations);

      // Wait for stream to process
      await Future.delayed(const Duration(milliseconds: 50));

      expect(filteredStations.value.length, 5);
    });

    test('filters stations by selected group', () async {
      setupFilteredStationsStream();

      final testStations = StationFactory.createPlaylist(count: 5);
      stations.add(testStations);

      // Create a group that contains only stations 1 and 3
      final group = StationFactory.createStationGroup(
        id: 1,
        name: 'Favorites Group',
        slug: 'favorites-group',
        stationToStationGroups: [
          StationFactory.createStationToStationGroup(stationId: 1, order: 0),
          StationFactory.createStationToStationGroup(stationId: 3, order: 1),
        ],
      );

      selectedStationGroup.add(group);

      await Future.delayed(const Duration(milliseconds: 50));

      expect(filteredStations.value.length, 2);
      expect(filteredStations.value[0].id, 1);
      expect(filteredStations.value[1].id, 3);
    });

    test('returns all stations when group is deselected', () async {
      setupFilteredStationsStream();

      final testStations = StationFactory.createPlaylist(count: 5);
      stations.add(testStations);

      // Select a group
      final group = StationFactory.createStationGroup(
        id: 1,
        name: 'Small Group',
        slug: 'small-group',
        stationToStationGroups: [
          StationFactory.createStationToStationGroup(stationId: 1),
        ],
      );
      selectedStationGroup.add(group);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(filteredStations.value.length, 1);

      // Deselect group
      selectedStationGroup.add(null);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(filteredStations.value.length, 5);
    });

    test('stations are sorted by order', () async {
      setupFilteredStationsStream();

      // Create stations with non-sequential order values
      final testStations = [
        StationFactory.createStation(
            id: 1, slug: 'c', title: 'Station C', order: 30),
        StationFactory.createStation(
            id: 2, slug: 'a', title: 'Station A', order: 10),
        StationFactory.createStation(
            id: 3, slug: 'b', title: 'Station B', order: 20),
      ];

      stations.add(testStations);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(filteredStations.value[0].slug, 'a');
      expect(filteredStations.value[1].slug, 'b');
      expect(filteredStations.value[2].slug, 'c');
    });

    test('empty group returns no stations', () async {
      setupFilteredStationsStream();

      final testStations = StationFactory.createPlaylist(count: 3);
      stations.add(testStations);

      final emptyGroup = StationFactory.createStationGroup(
        id: 1,
        name: 'Empty Group',
        slug: 'empty-group',
        stationToStationGroups: [],
      );

      selectedStationGroup.add(emptyGroup);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(filteredStations.value, isEmpty);
    });

    test('updates when stations list changes', () async {
      setupFilteredStationsStream();

      stations.add(StationFactory.createPlaylist(count: 3));
      await Future.delayed(const Duration(milliseconds: 50));
      expect(filteredStations.value.length, 3);

      // Add more stations
      stations.add(StationFactory.createPlaylist(count: 7));
      await Future.delayed(const Duration(milliseconds: 50));
      expect(filteredStations.value.length, 7);
    });
  });

  group('filterByGroup', () {
    /// The production shape: more than 32 stations, all with `order == 0`,
    /// where Dart's `List.sort` is no longer stable.
    List<Station> sameOrderCatalog() => List.generate(
          64,
          (i) => StationFactory.createStation(
              id: i + 1, slug: 'station-${i + 1}', title: 'Station ${i + 1}'),
        );

    List<int> idsOf(List<Station> stations) =>
        stations.map((s) => s.id as int).toList();

    test('keeps the input order for stations with equal order', () {
      final catalog = sameOrderCatalog();

      final result = StationDataService.filterByGroup(null, catalog);

      expect(idsOf(result), idsOf(catalog));
    });

    test('never mutates the published list or the group', () {
      final catalog = [
        StationFactory.createStation(id: 1, slug: 'c', title: 'C', order: 3),
        StationFactory.createStation(id: 2, slug: 'a', title: 'A', order: 1),
        StationFactory.createStation(id: 3, slug: 'b', title: 'B', order: 2),
      ];
      final group = StationFactory.createStationGroup(
        id: 1,
        name: 'Group',
        slug: 'group',
        stationToStationGroups: [
          StationFactory.createStationToStationGroup(stationId: 3, order: 1),
          StationFactory.createStationToStationGroup(stationId: 1, order: 0),
        ],
      );

      final result = StationDataService.filterByGroup(group, catalog);

      expect(idsOf(result), [3, 1]);
      expect(idsOf(catalog), [1, 2, 3]);
      expect(
        group.station_to_station_groups.map((e) => e.station_id).toList(),
        [3, 1],
      );
    });

    test('returns a new list even without a group', () {
      final catalog = StationFactory.createPlaylist(count: 3);

      final result = StationDataService.filterByGroup(null, catalog);

      expect(identical(result, catalog), isFalse);
    });

    test('an identical re-merge passes the change gate quietly', () {
      // Regression: the combiner used to sort the published list in place,
      // so the next merge (API order) never matched it and every refresh
      // re-emitted the whole catalog.
      final published = sameOrderCatalog();
      StationDataService.filterByGroup(null, published);

      expect(
        StationDataService.hasStationsChanged(published, sameOrderCatalog()),
        isFalse,
      );
    });
  });

  group('Station change detection', () {
    const hasStationsChanged = StationDataService.hasStationsChanged;

    Station withSong({String artist = 'Artist', String? thumbnail}) =>
        StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          nowPlaying: StationFactory.createNowPlaying(
            id: 1,
            songName: 'Song',
            artistName: artist,
            songThumbnailUrl: thumbnail,
          ),
        );

    test('returns false for identical station lists', () {
      final stations = StationFactory.createPlaylist(count: 3);
      // Create identical copies
      final sameStations = StationFactory.createPlaylist(count: 3);

      expect(hasStationsChanged(stations, sameStations), false);
    });

    test('returns true when station count changes', () {
      final stations3 = StationFactory.createPlaylist(count: 3);
      final stations5 = StationFactory.createPlaylist(count: 5);

      expect(hasStationsChanged(stations3, stations5), true);
    });

    test('returns true when a station title changes', () {
      final oldStations = StationFactory.createPlaylist(count: 3);
      final newStations = [
        StationFactory.createStation(
            id: 1, slug: 'station-1', title: 'New Title'),
        StationFactory.createStation(
            id: 2, slug: 'station-2', title: 'Station 2'),
        StationFactory.createStation(
            id: 3, slug: 'station-3', title: 'Station 3'),
      ];

      expect(hasStationsChanged(oldStations, newStations), true);
    });

    test('returns true when song changes (now_playing)', () {
      final oldStations = [
        StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          nowPlaying: StationFactory.createNowPlaying(
            id: 1,
            songName: 'Old Song',
          ),
        ),
      ];
      final newStations = [
        StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          nowPlaying: StationFactory.createNowPlaying(
            id: 2,
            songName: 'New Song',
          ),
        ),
      ];

      expect(hasStationsChanged(oldStations, newStations), true);
    });

    test('returns true when listener count changes', () {
      final oldStations = [
        StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          totalListeners: 10,
        ),
      ];
      final newStations = [
        StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          totalListeners: 25,
        ),
      ];

      expect(hasStationsChanged(oldStations, newStations), true);
    });

    test('returns true when station goes down', () {
      final oldStations = [
        StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          uptime: Query$GetStations$stations$uptime(
            is_up: true,
            timestamp: '2024-01-01T00:00:00Z',
          ),
        ),
      ];
      final newStations = [
        StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          uptime: Query$GetStations$stations$uptime(
            is_up: false,
            timestamp: '2024-01-01T00:01:00Z',
          ),
        ),
      ];

      expect(hasStationsChanged(oldStations, newStations), true);
    });

    test('returns false for empty lists', () {
      expect(hasStationsChanged([], []), false);
    });

    test('returns true when only the artist changes', () {
      expect(
        hasStationsChanged(
            [withSong(artist: 'Old')], [withSong(artist: 'New')]),
        true,
      );
    });

    test('returns true when only the song artwork changes', () {
      expect(
        hasStationsChanged([withSong(thumbnail: 'https://x/1.webp')],
            [withSong(thumbnail: 'https://x/2.webp')]),
        true,
      );
    });

    test('returns true when only the station logo changes', () {
      expect(
        hasStationsChanged([
          StationFactory.createStation(
              id: 1, slug: 'a', title: 'A', thumbnailUrl: 'https://x/1.png'),
        ], [
          StationFactory.createStation(
              id: 1, slug: 'a', title: 'A', thumbnailUrl: 'https://x/2.png'),
        ]),
        true,
      );
    });
  });
}
