import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

void main() {
  group('Station model', () {
    test('exposes correct id, slug, title, and order from raw data', () {
      final station = StationFactory.createStation(
        id: 42,
        slug: 'radio-test',
        title: 'Radio Test',
        order: 5,
      );

      expect(station.id, 42);
      expect(station.slug, 'radio-test');
      expect(station.title, 'Radio Test');
      expect(station.order, 5);
    });

    test('exposes totalListeners and thumbnailUrl', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        totalListeners: 150,
        thumbnailUrl: 'https://img.example.com/pic.jpg',
      );

      expect(station.totalListeners, 150);
      expect(station.thumbnailUrl, 'https://img.example.com/pic.jpg');
    });

    test('isUp returns true when uptime.is_up is true', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        uptime: Query$GetStations$stations$uptime(
          is_up: true,
          timestamp: '2024-01-01T00:00:00Z',
        ),
      );

      expect(station.isUp, true);
    });

    test('isUp returns false when uptime.is_up is false', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        uptime: Query$GetStations$stations$uptime(
          is_up: false,
          timestamp: '2024-01-01T00:00:00Z',
        ),
      );

      expect(station.isUp, false);
    });

    test('isUp returns false when uptime is null', () {
      final station = Station(
        rawStationData: Query$GetStations$stations(
          id: 1,
          slug: 'test',
          order: 0,
          title: 'Test',
          website: 'https://example.com',
          email: 'test@example.com',
          feature_latest_post: false,
          station_streams: [],
          posts: [],
          uptime: null,
          reviews: [],
        ),
      );

      expect(station.isUp, false);
    });

    test('displayTitle returns station title', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'test',
        title: 'My Radio Station',
      );

      expect(station.displayTitle, 'My Radio Station');
    });

    group('now playing metadata', () {
      test('songTitle and songArtist from now_playing', () {
        final station = StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          nowPlaying: StationFactory.createNowPlaying(
            songName: 'Amazing Grace',
            artistName: 'John Newton',
          ),
        );

        expect(station.songTitle, 'Amazing Grace');
        expect(station.songArtist, 'John Newton');
        expect(station.songId, 1);
      });

      test('songTitle and songArtist default when no now_playing', () {
        final station = StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          nowPlaying: null,
        );

        expect(station.songTitle, '');
        expect(station.songArtist, '');
        expect(station.songId, -1);
      });
    });

    group('mediaItem generation', () {
      test('generates MediaItem with correct stream URL as id', () {
        final station = StationFactory.createStation(
          id: 1,
          slug: 'radio-vocea',
          title: 'Radio Vocea Evangheliei',
          stationStreams: [
            Query$GetStations$stations$station_streams(
              order: 0,
              type: 'mp3',
              stream_url: 'https://stream1.example.com/live.mp3',
            ),
            Query$GetStations$stations$station_streams(
              order: 1,
              type: 'aac',
              stream_url: 'https://stream2.example.com/live.aac',
            ),
          ],
        );

        final item = station.mediaItem;
        expect(item, isA<MediaItem>());
        expect(item.id, 'https://stream1.example.com/live.mp3');
        expect(item.title, 'Radio Vocea Evangheliei');
        expect(item.displayTitle, 'Radio Vocea Evangheliei');
      });

      test('mediaItem extras contain station metadata', () {
        final station = StationFactory.createStation(
          id: 42,
          slug: 'test-station',
          title: 'Test Station',
          nowPlaying: StationFactory.createNowPlaying(
            songName: 'Test Song',
            artistName: 'Test Artist',
          ),
        );

        final extras = station.mediaItem.extras!;
        expect(extras['station_id'], 42);
        expect(extras['station_slug'], 'test-station');
        expect(extras['station_title'], 'Test Station');
        expect(extras['song_title'], 'Test Song');
        expect(extras['song_artist'], 'Test Artist');
        expect(extras['station_is_up'], true);
      });

      test('mediaItem extras contain all stream URLs', () {
        final station = StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          stationStreams: [
            Query$GetStations$stations$station_streams(
              order: 0,
              type: 'mp3',
              stream_url: 'https://stream1.example.com/live',
            ),
            Query$GetStations$stations$station_streams(
              order: 1,
              type: 'aac',
              stream_url: 'https://stream2.example.com/live',
            ),
          ],
        );

        final streamUrls = station.mediaItem.extras!['station_streams'] as List;
        expect(streamUrls.length, 2);
        expect(streamUrls[0], 'https://stream1.example.com/live');
        expect(streamUrls[1], 'https://stream2.example.com/live');
      });

      test('mediaItem id is empty string when no streams', () {
        final station = StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          stationStreams: [],
        );

        expect(station.mediaItem.id, '');
      });

      test('mediaItem artUri is a valid Uri', () {
        final station = StationFactory.createStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          thumbnailUrl: 'https://example.com/thumb.png',
        );

        expect(station.artUri, isA<Uri>());
        expect(station.artUri.scheme, 'https');
      });
    });
  });

  group('Station fromJson', () {
    test('parses station data from JSON correctly', () {
      final json = {
        'id': 1,
        'slug': 'radio-emanuel',
        'order': 0,
        'title': 'Radio Emanuel',
        'website': 'https://radioemanuel.ro',
        'email': 'contact@radioemanuel.ro',
        'thumbnail_url': 'https://example.com/thumb.png',
        'total_listeners': 25,
        'description': null,
        'description_action_title': null,
        'description_link': null,
        'feature_latest_post': false,
        'facebook_page_id': null,
        'station_streams': [
          {
            'order': 0,
            'type': 'mp3',
            'stream_url': 'https://stream.radioeman.ro/live',
            '__typename': 'StationStreamType',
          },
        ],
        'posts': [],
        'uptime': {
          'is_up': true,
          'latency_ms': 100,
          'timestamp': '2024-01-01T00:00:00Z',
          '__typename': 'StationUptimeType',
        },
        'now_playing': {
          'id': 1,
          'timestamp': '2024-01-01T00:00:00Z',
          'song': {
            'id': 10,
            'name': 'Great Song',
            'thumbnail_url': null,
            'artist': {
              'id': 5,
              'name': 'Great Artist',
              'thumbnail_url': null,
              '__typename': 'ArtistType',
            },
            '__typename': 'SongType',
          },
          '__typename': 'StationNowPlayingType',
        },
        'reviews': [],
        '__typename': 'StationType',
      };

      final rawStation = Query$GetStations$stations.fromJson(json);
      final station = Station(rawStationData: rawStation);

      expect(station.id, 1);
      expect(station.slug, 'radio-emanuel');
      expect(station.title, 'Radio Emanuel');
      expect(station.isUp, true);
      expect(station.songTitle, 'Great Song');
      expect(station.songArtist, 'Great Artist');
      expect(station.mediaItem.id, 'https://stream.radioeman.ro/live');
    });
  });
}
