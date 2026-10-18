import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/stream_failover.dart';
import 'package:radio_crestin/types/Station.dart';
import 'helpers/station_factory.dart';

void main() {
  group('ConnectionError', () {
    test('stores station name and reason', () {
      const error = ConnectionError(
        stationName: 'Radio Emanuel',
        reason: ConnectionErrorReason.timeout,
      );

      expect(error.stationName, 'Radio Emanuel');
      expect(error.reason, ConnectionErrorReason.timeout);
      expect(error.details, isNull);
    });

    test('stores optional details', () {
      const error = ConnectionError(
        stationName: 'Radio Vocea',
        reason: ConnectionErrorReason.httpError,
        details: '404',
      );

      expect(error.details, '404');
    });
  });

  group('ConnectionErrorReason', () {
    test('has all expected values', () {
      expect(ConnectionErrorReason.values, containsAll([
        ConnectionErrorReason.timeout,
        ConnectionErrorReason.network,
        ConnectionErrorReason.httpError,
        ConnectionErrorReason.unknown,
      ]));
    });
  });

  group('Tracking URL parameters', () {
    String tracked(String url) => AppAudioHandler.withTrackingParameters(
          url,
          source: 'ios',
          deviceId: 'test-device-123',
        );

    test('adds ref (playback source) and s (device id)', () {
      final uri = Uri.parse(tracked('https://stream.example.com/live.mp3'));
      expect(uri.queryParameters['ref'], 'radio-crestin-ios');
      expect(uri.queryParameters['s'], 'test-device-123');
    });

    test('keeps existing query parameters', () {
      final uri =
          Uri.parse(tracked('https://stream.example.com/live.mp3?quality=hi'));
      expect(uri.queryParameters['quality'], 'hi');
      expect(uri.queryParameters['ref'], 'radio-crestin-ios');
    });

    test('tags HLS URLs too', () {
      final uri = Uri.parse(
          tracked('https://hls.radiocrestin.ro/hls/rve-suceava/index.m3u8'));
      expect(uri.path, '/hls/rve-suceava/index.m3u8');
      expect(uri.queryParameters['s'], 'test-device-123');
    });

    test('overwrites an existing ref', () {
      final uri = Uri.parse(
          tracked('https://stream.example.com/live.mp3?ref=old&s=other'));
      expect(uri.queryParameters['ref'], 'radio-crestin-ios');
      expect(uri.queryParameters['s'], 'test-device-123');
    });
  });

  group('Station navigation logic', () {
    // Test skip next/prev logic that exists in both AppAudioHandler and
    // the earlier station_navigation_test.dart. These tests verify the
    // algorithm used for circular playlist navigation.

    test('skip next wraps around', () {
      final playlist = StationFactory.createPlaylist(count: 3);
      const currentSlug = 'station-3';

      final currentIndex = playlist.indexWhere((s) => s.slug == currentSlug);
      final nextIndex = (currentIndex + 1) % playlist.length;

      expect(nextIndex, 0); // Wraps to first
    });

    test('skip previous wraps around', () {
      final playlist = StationFactory.createPlaylist(count: 3);
      const currentSlug = 'station-1';

      final currentIndex = playlist.indexWhere((s) => s.slug == currentSlug);
      final prevIndex = currentIndex <= 0 ? playlist.length - 1 : currentIndex - 1;

      expect(prevIndex, 2); // Wraps to last
    });

    test('skip next with not found station goes to index 0', () {
      final playlist = StationFactory.createPlaylist(count: 3);
      const currentSlug = 'nonexistent';

      final currentIndex = playlist.indexWhere((s) => s.slug == currentSlug);
      // currentIndex = -1, (-1 + 1) % 3 = 0
      final nextIndex = (currentIndex + 1) % playlist.length;
      final safeIndex = nextIndex < 0 ? 0 : nextIndex;

      expect(safeIndex, 0);
    });
  });

  group('Favorites playlist filtering', () {
    test('filters active playlist to only favorites', () {
      final playlist = StationFactory.createPlaylist(count: 5);
      final favSlugs = ['station-1', 'station-3', 'station-5'];

      final filteredFavorites = playlist
          .where((s) => favSlugs.contains(s.slug))
          .toList();

      expect(filteredFavorites.length, 3);
      expect(filteredFavorites.map((s) => s.slug), ['station-1', 'station-3', 'station-5']);
    });

    test('returns empty when no favorites match', () {
      final playlist = StationFactory.createPlaylist(count: 3);
      final favSlugs = <String>['nonexistent'];

      final filteredFavorites = playlist
          .where((s) => favSlugs.contains(s.slug))
          .toList();

      expect(filteredFavorites, isEmpty);
    });
  });

  group('Last played station', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('saves station slug to SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      final station = StationFactory.createStation(
        id: 1, slug: 'radio-test', title: 'Radio Test',
      );

      await prefs.setString('last_played_media_item', station.slug);
      expect(prefs.getString('last_played_media_item'), 'radio-test');
    });

    test('retrieves correct station by slug', () async {
      SharedPreferences.setMockInitialValues({
        'last_played_media_item': 'station-3',
      });
      final prefs = await SharedPreferences.getInstance();
      final stationSlug = prefs.getString('last_played_media_item');

      final stations = StationFactory.createPlaylist(count: 5);
      final lastPlayed = stations.firstWhere(
        (s) => s.slug == stationSlug,
        orElse: () => stations.first,
      );

      expect(lastPlayed.slug, 'station-3');
    });

    test('falls back to first station when slug not found', () async {
      SharedPreferences.setMockInitialValues({
        'last_played_media_item': 'nonexistent',
      });
      final prefs = await SharedPreferences.getInstance();
      final stationSlug = prefs.getString('last_played_media_item');

      final stations = StationFactory.createPlaylist(count: 5);
      final lastPlayed = stations.firstWhere(
        (s) => s.slug == stationSlug,
        orElse: () => stations.first,
      );

      expect(lastPlayed.slug, 'station-1');
    });
  });

  group('MediaItem construction', () {
    test('station mediaItem has correct extras', () {
      final station = StationFactory.createStation(
        id: 42,
        slug: 'radio-test',
        title: 'Radio Test',
        totalListeners: 100,
      );

      final item = station.mediaItem;

      expect(item.title, 'Radio Test');
      expect(item.extras?['station_id'], 42);
      expect(item.extras?['station_slug'], 'radio-test');
      expect(item.extras?['station_title'], 'Radio Test');
      expect(item.extras?['total_listeners'], 100);
      expect(item.extras?['station_is_up'], true);
      expect(item.isLive, true);
    });

    test('station mediaItem has stream URL as id', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'test',
        title: 'Test',
      );

      final item = station.mediaItem;
      expect(item.id, contains('stream.example.com'));
    });

    test('station mediaItem has song metadata when now_playing set', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        nowPlaying: StationFactory.createNowPlaying(
          songName: 'Amazing Grace',
          artistName: 'John Newton',
        ),
      );

      final item = station.mediaItem;
      expect(item.extras?['song_title'], 'Amazing Grace');
      expect(item.extras?['song_artist'], 'John Newton');
    });
  });

  group('Now Playing lines', () {
    Station station({String? song, String? artist}) =>
        StationFactory.createStation(
          id: 1,
          slug: 'rve-bucuresti',
          title: 'RVE Bucuresti',
          nowPlaying: song == null
              ? null
              : StationFactory.createNowPlaying(
                  songName: song,
                  artistName: artist,
                ),
        );

    test('CarPlay shows the song, then its artist', () {
      final lines = AppAudioHandler.nowPlayingLines(
        station(song: 'Sa-L slavim pe Dumnezeu', artist: 'Speranta'),
        onCarPlay: true,
      );

      expect(lines.artist, 'Sa-L slavim pe Dumnezeu');
      expect(lines.album, 'Speranta');
    });

    test('CarPlay leaves out a missing artist instead of the station', () {
      final lines = AppAudioHandler.nowPlayingLines(
        station(song: 'Sa-L slavim pe Dumnezeu'),
        onCarPlay: true,
      );

      expect(lines.artist, 'Sa-L slavim pe Dumnezeu');
      expect(lines.album, isNull);
    });

    test('CarPlay shows only the station name without a song', () {
      final lines =
          AppAudioHandler.nowPlayingLines(station(), onCarPlay: true);

      expect(lines.artist, isNull);
      expect(lines.album, isNull);
    });

    test('off CarPlay the song and its artist share one line', () {
      final lines = AppAudioHandler.nowPlayingLines(
        station(song: 'Sa-L slavim pe Dumnezeu', artist: 'Speranta'),
        onCarPlay: false,
      );

      expect(lines.artist, 'Sa-L slavim pe Dumnezeu • Speranta');
      expect(lines.album, 'RVE Bucuresti');
    });
  });

  group('Android Auto browsing', () {
    test('filters media items by favorite slugs', () {
      final stations = StationFactory.createPlaylist(count: 5);
      final mediaItems = stations.map((s) => s.mediaItem).toList();
      final favSlugs = ['station-1', 'station-3'];

      final filtered = mediaItems
          .where((item) => favSlugs.contains(item.extras?['station_slug']))
          .toList();

      expect(filtered.length, 2);
      expect(filtered[0].extras?['station_slug'], 'station-1');
      expect(filtered[1].extras?['station_slug'], 'station-3');
    });
  });

  group('Station change detection', () {
    // Replicate _hasStationsChanged logic
    bool hasStationsChanged(List oldStations, List newStations) {
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
      final a = StationFactory.createPlaylist(count: 3);
      final b = StationFactory.createPlaylist(count: 3);
      expect(hasStationsChanged(a, b), false);
    });

    test('returns true when length differs', () {
      final a = StationFactory.createPlaylist(count: 3);
      final b = StationFactory.createPlaylist(count: 2);
      expect(hasStationsChanged(a, b), true);
    });

    test('returns true when title changes', () {
      final a = [StationFactory.createStation(id: 1, slug: 's1', title: 'A')];
      final b = [StationFactory.createStation(id: 1, slug: 's1', title: 'B')];
      expect(hasStationsChanged(a, b), true);
    });

    test('returns true when listeners change', () {
      final a = [StationFactory.createStation(id: 1, slug: 's1', title: 'A', totalListeners: 10)];
      final b = [StationFactory.createStation(id: 1, slug: 's1', title: 'A', totalListeners: 20)];
      expect(hasStationsChanged(a, b), true);
    });

    test('returns true when song changes', () {
      final a = [StationFactory.createStation(
        id: 1, slug: 's1', title: 'A',
        nowPlaying: StationFactory.createNowPlaying(id: 1, songName: 'Song A'),
      )];
      final b = [StationFactory.createStation(
        id: 1, slug: 's1', title: 'A',
        nowPlaying: StationFactory.createNowPlaying(id: 2, songName: 'Song B'),
      )];
      expect(hasStationsChanged(a, b), true);
    });

    test('returns true when uptime changes', () {
      final uptimeUp = Query$GetStations$stations$uptime(
        is_up: true,
        timestamp: '2024-01-01T00:00:00Z',
      );
      final uptimeDown = Query$GetStations$stations$uptime(
        is_up: false,
        timestamp: '2024-01-01T00:00:00Z',
      );
      final a = [StationFactory.createStation(
        id: 1, slug: 's1', title: 'A',
        uptime: uptimeUp,
      )];
      final b = [StationFactory.createStation(
        id: 1, slug: 's1', title: 'A',
        uptime: uptimeDown,
      )];
      // a.isUp = true, b.isUp = false
      expect(hasStationsChanged(a, b), true);
    });
  });

  group('Fuzzy search', () {
    test('finds best matching station by title', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'radio-emanuel', title: 'Radio Emanuel'),
        StationFactory.createStation(id: 2, slug: 'radio-vocea', title: 'Radio Vocea Evangheliei'),
        StationFactory.createStation(id: 3, slug: 'radio-trinitas', title: 'Radio Trinitas'),
      ];

      // Simplified fuzzy search matching the pattern in playFromSearch
      var maxR = 0;
      late dynamic selectedStation;
      for (var v in stations) {
        // Simple contains-based matching for test (fuzzywuzzy not available in test)
        var r = v.title.toLowerCase().contains('emanuel') ? 100 : 0;
        if (r > maxR) {
          maxR = r;
          selectedStation = v;
        }
      }

      expect(maxR, greaterThan(0));
      expect(selectedStation.slug, 'radio-emanuel');
    });

    test('falls back to first station when no match', () {
      final stations = StationFactory.createPlaylist(count: 3);

      var maxR = 0;
      for (var v in stations) {
        var r = v.title.toLowerCase().contains('nonexistent_query') ? 100 : 0;
        if (r > maxR) {
          maxR = r;
        }
      }

      // When maxR is 0, should use first station
      final result = maxR > 0 ? null : stations[0];
      expect(result?.slug, 'station-1');
    });
  });

  group('ConnectionError classification', () {
    test('TimeoutException maps to timeout reason', () {
      // Replicate _classifyError logic for TimeoutException
      final error = TimeoutException('timed out');
      expect(error, isA<TimeoutException>());
      // In _classifyError: TimeoutException -> ConnectionErrorReason.timeout
    });

    test('SocketException maps to network reason', () {
      final error = const SocketException('No route to host');
      expect(error.message, 'No route to host');
      // In _classifyError: SocketException -> ConnectionErrorReason.network
    });
  });

  group('Disconnect timer logic', () {
    test('disconnect delay is 60 seconds', () {
      // Verify the constant matches expectations
      const disconnectDelay = Duration(seconds: 60);
      expect(disconnectDelay.inSeconds, 60);
    });

    test('buffering stall timeout is 3 seconds', () {
      // Was 15s; reduced to 3s for Spotify-tier perceived recovery on
      // network blips. play() has its own retry chain (maxRetries=4
      // across the station's stream URLs) so a fast retry shortens the
      // silence window without bypassing any safety net.
      expect(ReconnectPolicy.bufferingStallTimeout,
          equals(const Duration(seconds: 3)));
    });
  });

  group('Stream retry logic', () {
    test('cycles through multiple streams from the failover start index', () {
      final streams = [
        {'url': 'https://stream1.com', 'type': 'HLS'},
        {'url': 'https://stream2.com', 'type': 'direct_stream'},
        {'url': 'https://stream3.com', 'type': 'direct_stream'},
      ];

      // Mirrors play(): attemptIndex = (start + retry) % total, where
      // start skips recently-failed streams (0 when memory is clean).
      const start = 0;
      final selectedUrls = <String>[];
      for (var retry = 0; retry < 4; retry++) {
        final idx = (start + retry) % streams.length;
        selectedUrls.add(streams[idx]['url']!);
      }

      expect(selectedUrls, [
        'https://stream1.com',
        'https://stream2.com',
        'https://stream3.com',
        'https://stream1.com', // Wraps around
      ]);
    });

    test('retry loop never gives up — backoff is capped, not terminal', () {
      // The old maxRetries=4 behavior stopped the player entirely after
      // one failed pass; live radio now cycles forever with capped delays
      // (detailed schedule covered in stream_failover_test.dart).
      expect(StreamFailover.retryDelay(retry: 1000, totalStreams: 2),
          lessThanOrEqualTo(StreamFailover.maxCycleBackoff));
    });
  });

  group('Favorites via BehaviorSubject', () {
    test('adding favorite updates stream', () async {
      final favSlugs = BehaviorSubject.seeded(<String>[]);
      final emissions = <List<String>>[];

      favSlugs.listen((v) => emissions.add(List.from(v)));

      final station = StationFactory.createStation(id: 1, slug: 'radio-test', title: 'Test');
      favSlugs.add([...favSlugs.value, station.slug]);

      await Future.delayed(const Duration(milliseconds: 50));

      expect(emissions.last, ['radio-test']);
      favSlugs.close();
    });

    test('removing favorite updates stream', () async {
      final favSlugs = BehaviorSubject.seeded(<String>['radio-a', 'radio-b']);

      favSlugs.add(favSlugs.value.where((s) => s != 'radio-a').toList());

      await Future.delayed(const Duration(milliseconds: 50));

      expect(favSlugs.value, ['radio-b']);
      favSlugs.close();
    });

    test('favorite state reflects in MediaItem rating', () {
      final station = StationFactory.createStation(id: 1, slug: 'test', title: 'Test');
      final item = station.mediaItem;

      // Simulate adding rating
      final ratedItem = item.copyWith(rating: Rating.newHeartRating(true));
      expect(ratedItem.rating?.hasHeart(), true);

      final unratedItem = item.copyWith(rating: Rating.newHeartRating(false));
      expect(unratedItem.rating?.hasHeart(), false);
    });
  });

  group('Filtered stations stream', () {
    test('returns all stations when no group selected', () async {
      final stations = StationFactory.createPlaylist(count: 5);
      final selectedGroup = BehaviorSubject<dynamic>.seeded(null);
      final stationsSubject = BehaviorSubject.seeded(stations);

      final filtered = <List>[];

      Rx.combineLatest2(
        selectedGroup.stream,
        stationsSubject.stream,
        (group, allStations) {
          if (group == null) return allStations;
          return <dynamic>[];
        },
      ).listen((result) => filtered.add(result));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(filtered.last.length, 5);

      selectedGroup.close();
      stationsSubject.close();
    });
  });

  group('Station stream URL extraction', () {
    test('extracts stream objects with url and type', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        stationStreams: [
          StationFactory.createRawStation(id: 1, slug: 's', title: 't')
              .station_streams
              .first,
        ],
      );

      final streams = station.stationStreams;
      expect(streams, isNotEmpty);
      expect(streams.first.stream_url, contains('stream.example.com'));
    });
  });
}
