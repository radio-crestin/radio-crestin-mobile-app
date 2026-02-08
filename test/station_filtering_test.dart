import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';

import 'helpers/station_factory.dart';

void main() {
  group('Station filtering logic', () {
    late BehaviorSubject<Query$GetStations$station_groups?> selectedStationGroup;
    late BehaviorSubject<List<Station>> stations;
    late BehaviorSubject<List<Station>> filteredStations;

    /// Replicates _initFilteredStationsStream from AppAudioHandler
    void setupFilteredStationsStream() {
      final combinedStream = Rx.combineLatest2<
          Query$GetStations$station_groups?, List<Station>, List<Station>>(
        selectedStationGroup.stream,
        stations.stream,
        (selectedGroup, allStations) {
          allStations.sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
          if (selectedGroup == null) {
            return allStations;
          }
          selectedGroup.station_to_station_groups
              .sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
          final selectedStationsIds = selectedGroup.station_to_station_groups
              .map((e) => e.station_id);
          return allStations.where((station) {
            return selectedStationsIds.contains(station.id);
          }).toList();
        },
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

  group('Station change detection', () {
    /// Replicates _hasStationsChanged from AppAudioHandler
    bool hasStationsChanged(
        List<Station> oldStations, List<Station> newStations) {
      if (oldStations.length != newStations.length) return true;
      for (int i = 0; i < oldStations.length; i++) {
        final o = oldStations[i];
        final n = newStations[i];
        if (o.id != n.id ||
            o.title != n.title ||
            o.songId != n.songId ||
            o.songTitle != n.songTitle ||
            o.totalListeners != n.totalListeners ||
            o.isUp != n.isUp) {
          return true;
        }
      }
      return false;
    }

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
  });
}
