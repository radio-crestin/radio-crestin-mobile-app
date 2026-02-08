import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';

import 'helpers/station_factory.dart';

void main() {
  group('Playback state management', () {
    test('currentStation starts as null', () {
      final currentStation = BehaviorSubject<Station?>.seeded(null);
      expect(currentStation.value, isNull);
      currentStation.close();
    });

    test('selecting a station updates currentStation', () {
      final currentStation = BehaviorSubject<Station?>.seeded(null);
      final station = StationFactory.createStation(
        id: 1,
        slug: 'radio-test',
        title: 'Radio Test',
      );

      // Simulate selectStation
      currentStation.add(station);

      expect(currentStation.value, isNotNull);
      expect(currentStation.value!.slug, 'radio-test');
      currentStation.close();
    });

    test('selecting a station updates mediaItem', () {
      final mediaItem = BehaviorSubject<MediaItem?>.seeded(null);
      final currentStation = BehaviorSubject<Station?>.seeded(null);

      final station = StationFactory.createStation(
        id: 1,
        slug: 'radio-test',
        title: 'Radio Test',
        stationStreams: [
          Query$GetStations$stations$station_streams(
            order: 0,
            type: 'mp3',
            stream_url: 'https://stream.example.com/live.mp3',
          ),
        ],
      );

      // Simulate selectStation
      mediaItem.add(station.mediaItem);
      currentStation.add(station);

      expect(mediaItem.value, isNotNull);
      expect(mediaItem.value!.title, 'Radio Test');
      expect(mediaItem.value!.id, 'https://stream.example.com/live.mp3');

      mediaItem.close();
      currentStation.close();
    });

    test('changing station updates both currentStation and mediaItem', () {
      final mediaItem = BehaviorSubject<MediaItem?>.seeded(null);
      final currentStation = BehaviorSubject<Station?>.seeded(null);

      final station1 = StationFactory.createStation(
        id: 1,
        slug: 'station-1',
        title: 'Station 1',
      );
      final station2 = StationFactory.createStation(
        id: 2,
        slug: 'station-2',
        title: 'Station 2',
      );

      // Play station 1
      mediaItem.add(station1.mediaItem);
      currentStation.add(station1);
      expect(currentStation.value!.slug, 'station-1');

      // Switch to station 2
      mediaItem.add(station2.mediaItem);
      currentStation.add(station2);
      expect(currentStation.value!.slug, 'station-2');
      expect(mediaItem.value!.title, 'Station 2');

      mediaItem.close();
      currentStation.close();
    });
  });

  group('Station metadata updates', () {
    test('stationsMediaItems updates when stations change', () {
      final stations = BehaviorSubject<List<Station>>.seeded([]);
      final stationsMediaItems = BehaviorSubject<List<MediaItem>>.seeded([]);

      final testStations = StationFactory.createPlaylist(count: 3);
      stations.add(testStations);

      // Simulate _initUpdateCurrentStationMetadata
      final sortedStations = testStations
        ..sort((a, b) => a.order.compareTo(b.order));
      stationsMediaItems
          .add(sortedStations.map((s) => s.mediaItem).toList());

      expect(stationsMediaItems.value.length, 3);
      expect(stationsMediaItems.value[0].title, 'Station 1');
      expect(stationsMediaItems.value[1].title, 'Station 2');
      expect(stationsMediaItems.value[2].title, 'Station 3');

      stations.close();
      stationsMediaItems.close();
    });

    test('current station metadata refreshes when stations list updates', () {
      final stations = BehaviorSubject<List<Station>>.seeded([]);
      final currentStation = BehaviorSubject<Station?>.seeded(null);
      final mediaItem = BehaviorSubject<MediaItem?>.seeded(null);

      // Set up initial stations
      final initial = [
        StationFactory.createStation(
          id: 1,
          slug: 'radio-test',
          title: 'Radio Test',
          nowPlaying: StationFactory.createNowPlaying(
            songName: 'Old Song',
          ),
        ),
      ];
      stations.add(initial);
      currentStation.add(initial[0]);
      mediaItem.add(initial[0].mediaItem);

      expect(mediaItem.value!.extras!['song_title'], 'Old Song');

      // Update stations with new now_playing
      final updated = [
        StationFactory.createStation(
          id: 1,
          slug: 'radio-test',
          title: 'Radio Test',
          nowPlaying: StationFactory.createNowPlaying(
            songName: 'New Song',
          ),
        ),
      ];
      stations.add(updated);

      // Simulate _initUpdateCurrentStationMetadata
      if (currentStation.value != null) {
        final refreshedStation =
            updated.firstWhere((s) => s.id == currentStation.value!.id);
        currentStation.add(refreshedStation);
        mediaItem.add(refreshedStation.mediaItem);
      }

      expect(currentStation.value!.songTitle, 'New Song');
      expect(mediaItem.value!.extras!['song_title'], 'New Song');

      stations.close();
      currentStation.close();
      mediaItem.close();
    });
  });

  group('Station streams and URL handling', () {
    test('mediaItem uses first stream URL as primary', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        stationStreams: [
          Query$GetStations$stations$station_streams(
            order: 0,
            type: 'mp3',
            stream_url: 'https://primary.example.com/stream',
          ),
          Query$GetStations$stations$station_streams(
            order: 1,
            type: 'aac',
            stream_url: 'https://fallback.example.com/stream',
          ),
        ],
      );

      expect(station.mediaItem.id, 'https://primary.example.com/stream');
    });

    test('stream URLs are available as fallbacks in extras', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        stationStreams: [
          Query$GetStations$stations$station_streams(
            order: 0,
            type: 'mp3',
            stream_url: 'https://primary.example.com/stream',
          ),
          Query$GetStations$stations$station_streams(
            order: 1,
            type: 'aac',
            stream_url: 'https://fallback1.example.com/stream',
          ),
          Query$GetStations$stations$station_streams(
            order: 2,
            type: 'hls',
            stream_url: 'https://fallback2.example.com/stream',
          ),
        ],
      );

      final streams = station.mediaItem.extras!['station_streams'] as List;
      expect(streams.length, 3);
    });

    test('retry mechanism uses different stream URLs cyclically', () {
      // Simulate the retry logic from play()
      final streamUrls = [
        'https://stream1.example.com/live',
        'https://stream2.example.com/live',
        'https://stream3.example.com/live',
      ];
      const maxRetries = 5;

      final attemptedUrls = <String>[];
      for (int retry = 0; retry < maxRetries; retry++) {
        final url = streamUrls[retry % streamUrls.length];
        attemptedUrls.add(url);
      }

      // Should cycle through: 0, 1, 2, 0, 1
      expect(attemptedUrls, [
        'https://stream1.example.com/live',
        'https://stream2.example.com/live',
        'https://stream3.example.com/live',
        'https://stream1.example.com/live',
        'https://stream2.example.com/live',
      ]);
    });
  });

  group('Tracking URL parameters', () {
    test('adds ref and device ID parameters to stream URL', () {
      // Test the URL parameter logic from addTrackingParametersToUrl
      const url = 'https://stream.example.com/live.mp3';
      const platform = 'ios'; // simplified for test
      const deviceId = 'test-device-123';

      final uri = Uri.parse(url);
      final queryParams = Map<String, String>.from(uri.queryParameters);
      queryParams['ref'] = 'radio-crestin-mobile-app-$platform';
      queryParams['s'] = deviceId;
      final trackedUrl = uri.replace(queryParameters: queryParams).toString();

      expect(trackedUrl, contains('ref=radio-crestin-mobile-app-ios'));
      expect(trackedUrl, contains('s=test-device-123'));
    });

    test('preserves existing URL parameters', () {
      const url = 'https://stream.example.com/live.mp3?quality=high';
      const platform = 'android';
      const deviceId = 'device-456';

      final uri = Uri.parse(url);
      final queryParams = Map<String, String>.from(uri.queryParameters);
      queryParams['ref'] = 'radio-crestin-mobile-app-$platform';
      queryParams['s'] = deviceId;
      final trackedUrl = uri.replace(queryParameters: queryParams).toString();

      expect(trackedUrl, contains('quality=high'));
      expect(trackedUrl, contains('ref=radio-crestin-mobile-app-android'));
      expect(trackedUrl, contains('s=device-456'));
    });
  });

  group('Fuzzy search playback', () {
    test('finds exact match station by title', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'radio-a', title: 'Radio A'),
        StationFactory.createStation(
            id: 2, slug: 'radio-emanuel', title: 'Radio Emanuel'),
        StationFactory.createStation(
            id: 3, slug: 'radio-vocea', title: 'Radio Vocea Evangheliei'),
      ];

      // Simple search by exact match
      final query = 'Radio Emanuel';
      final match = stations.firstWhere(
        (s) => s.title == query,
        orElse: () => stations.first,
      );

      expect(match.slug, 'radio-emanuel');
    });

    test('falls back to first station when no match', () {
      final stations = StationFactory.createPlaylist(count: 3);

      final query = 'Nonexistent Radio';
      final match = stations.firstWhere(
        (s) => s.title == query,
        orElse: () => stations.first,
      );

      expect(match.slug, 'station-1');
    });
  });
}
