import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/constants.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/utils.dart';

import 'helpers/station_factory.dart';

void main() {
  setUpAll(() {
    // NetworkService is needed by Utils.getStationThumbnailUrl
    NetworkService();
  });
  group('Utils.getCurrentPlayedSongTitle', () {
    test('returns empty string for null station', () {
      expect(Utils.getCurrentPlayedSongTitle(null), '');
    });

    test('returns song name when only song name is set', () {
      final raw = StationFactory.createRawStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        nowPlaying: StationFactory.createNowPlaying(
          songName: 'Holy Holy Holy',
          artistName: null,
        ),
      );

      expect(Utils.getCurrentPlayedSongTitle(raw), 'Holy Holy Holy');
    });

    test('returns "song name - artist name" when both are set', () {
      final raw = StationFactory.createRawStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        nowPlaying: StationFactory.createNowPlaying(
          songName: 'Amazing Grace',
          artistName: 'John Newton',
        ),
      );

      final result = Utils.getCurrentPlayedSongTitle(raw);
      expect(result, contains('Amazing Grace'));
      expect(result, contains('John Newton'));
    });

    test('returns empty string when no now_playing', () {
      final raw = StationFactory.createRawStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        nowPlaying: null,
      );

      expect(Utils.getCurrentPlayedSongTitle(raw), '');
    });
  });

  group('Utils.getStationThumbnailUrl', () {
    setUp(() {
      // Reset constants for test isolation
      CONSTANTS.IMAGE_PROXY_PREFIX = '';
      CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL = '';
    });

    test('returns empty string for null station', () {
      expect(Utils.getStationThumbnailUrl(null), '');
    });

    test('returns station thumbnail_url when no song thumbnail', () {
      final raw = StationFactory.createRawStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        thumbnailUrl: 'https://example.com/station_thumb.png',
        nowPlaying: null,
      );

      expect(
        Utils.getStationThumbnailUrl(raw),
        'https://example.com/station_thumb.png',
      );
    });

    test('returns song thumbnail_url when available', () {
      final raw = StationFactory.createRawStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        thumbnailUrl: 'https://example.com/station_thumb.png',
        nowPlaying: StationFactory.createNowPlaying(
          songName: 'Test Song',
          songThumbnailUrl: 'https://example.com/song_thumb.png',
        ),
      );

      expect(
        Utils.getStationThumbnailUrl(raw),
        'https://example.com/song_thumb.png',
      );
    });

    test('prepends IMAGE_PROXY_PREFIX when set', () {
      CONSTANTS.IMAGE_PROXY_PREFIX = 'https://proxy.example.com/';
      final raw = StationFactory.createRawStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        thumbnailUrl: 'https://example.com/thumb.png',
        nowPlaying: null,
      );

      expect(
        Utils.getStationThumbnailUrl(raw),
        'https://proxy.example.com/https://example.com/thumb.png',
      );
    });

    test('returns DEFAULT_STATION_THUMBNAIL_URL when station has no thumbnail', () {
      CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL = 'https://default.example.com/default.png';
      final raw = StationFactory.createRawStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        thumbnailUrl: null,
        nowPlaying: null,
      );

      expect(
        Utils.getStationThumbnailUrl(raw),
        'https://default.example.com/default.png',
      );
    });
  });

  group('Utils.withCdnWidth', () {
    const cdn = 'https://cdn.radiocrestin.ro/?url=https%3A%2F%2Fexample.com'
        '%2Fw%3D1.png&sig=abc&w=250&f=webp&max_age=2592000';

    test('asks the CDN for the next 250px step, keeping the rest', () {
      expect(
        Utils.withCdnWidth(cdn, 867),
        cdn.replaceFirst('&w=250&', '&w=1000&'),
      );
      expect(
        Utils.withCdnWidth(cdn, 420),
        cdn.replaceFirst('&w=250&', '&w=500&'),
      );
    });

    test('caps the width at 1000', () {
      expect(
        Utils.withCdnWidth(cdn, 2400),
        cdn.replaceFirst('&w=250&', '&w=1000&'),
      );
    });

    test('never asks for less than the URL already has', () {
      expect(Utils.withCdnWidth(cdn, 200), cdn);
      final wide = cdn.replaceFirst('&w=250&', '&w=1000&');
      expect(Utils.withCdnWidth(wide, 500), wide);
    });

    test('leaves URLs outside the CDN unchanged', () {
      const other = 'https://example.com/thumb.png?w=250';
      expect(Utils.withCdnWidth(other, 1000), other);
      expect(Utils.withCdnWidth('', 1000), '');
    });
  });

  group('Utils.getStationStreamUrls', () {
    test('returns empty list for null station', () {
      expect(Utils.getStationStreamUrls(null), isEmpty);
    });

    test('returns stream URLs sorted by order', () {
      final raw = StationFactory.createRawStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        stationStreams: [
          Query$GetStations$stations$station_streams(
            order: 2,
            type: 'aac',
            stream_url: 'https://stream2.example.com/live',
          ),
          Query$GetStations$stations$station_streams(
            order: 0,
            type: 'mp3',
            stream_url: 'https://stream0.example.com/live',
          ),
          Query$GetStations$stations$station_streams(
            order: 1,
            type: 'hls',
            stream_url: 'https://stream1.example.com/live',
          ),
        ],
      );

      final urls = Utils.getStationStreamUrls(raw);
      expect(urls.length, 3);
      expect(urls[0], 'https://stream0.example.com/live');
      expect(urls[1], 'https://stream1.example.com/live');
      expect(urls[2], 'https://stream2.example.com/live');
    });

    test('returns empty list when station has no streams', () {
      final raw = StationFactory.createRawStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        stationStreams: [],
      );

      expect(Utils.getStationStreamUrls(raw), isEmpty);
    });
  });
}
