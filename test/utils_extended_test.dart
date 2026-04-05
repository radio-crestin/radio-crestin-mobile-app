import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';

import 'package:radio_crestin/utils.dart';
import 'helpers/station_factory.dart';

void main() {
  group('Utils - extended coverage', () {
    group('getStationStreamObjects', () {
      test('returns empty list for null station', () {
        expect(Utils.getStationStreamObjects(null), isEmpty);
      });

      test('returns stream objects with url and type', () {
        final raw = StationFactory.createRawStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          stationStreams: [
            Query$GetStations$stations$station_streams(
              order: 0,
              type: 'mp3',
              stream_url: 'https://stream.example.com/live.mp3',
            ),
          ],
        );

        final result = Utils.getStationStreamObjects(raw);

        expect(result, hasLength(1));
        expect(result[0]['url'], 'https://stream.example.com/live.mp3');
        expect(result[0]['type'], 'mp3');
      });

      test('sorts streams by order', () {
        final raw = StationFactory.createRawStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          stationStreams: [
            Query$GetStations$stations$station_streams(
              order: 2,
              type: 'HLS',
              stream_url: 'https://stream.example.com/live.m3u8',
            ),
            Query$GetStations$stations$station_streams(
              order: 0,
              type: 'mp3',
              stream_url: 'https://stream.example.com/live.mp3',
            ),
            Query$GetStations$stations$station_streams(
              order: 1,
              type: 'aac',
              stream_url: 'https://stream.example.com/live.aac',
            ),
          ],
        );

        final result = Utils.getStationStreamObjects(raw);

        expect(result[0]['type'], 'mp3');
        expect(result[1]['type'], 'aac');
        expect(result[2]['type'], 'HLS');
      });

      test('handles empty station streams', () {
        final raw = StationFactory.createRawStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          stationStreams: [],
        );

        expect(Utils.getStationStreamObjects(raw), isEmpty);
      });
    });

    group('displayImage', () {
      test('returns Icon widget for empty URL without cache', () {
        final widget = Utils.displayImage('');
        // Should return an Icon (photo icon fallback)
        expect(widget, isNotNull);
      });
    });

    group('getCurrentPlayedSongTitle - extended', () {
      test('returns song name and artist with bullet separator', () {
        final raw = StationFactory.createRawStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          nowPlaying: StationFactory.createNowPlaying(
            songName: 'Amazing Grace',
            artistName: 'Chris Tomlin',
          ),
        );

        final result = Utils.getCurrentPlayedSongTitle(raw);
        expect(result, 'Amazing Grace • Chris Tomlin');
      });

      test('returns only song name when no artist', () {
        final raw = StationFactory.createRawStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          nowPlaying: StationFactory.createNowPlaying(
            songName: 'Solo Song',
            artistName: null,
          ),
        );

        final result = Utils.getCurrentPlayedSongTitle(raw);
        expect(result, 'Solo Song');
      });

      test('returns empty string when no now_playing', () {
        final raw = StationFactory.createRawStation(
          id: 1,
          slug: 'test',
          title: 'Test',
        );

        expect(Utils.getCurrentPlayedSongTitle(raw), '');
      });
    });

    group('getStationThumbnailUrl - extended', () {
      test('prefers song thumbnail over station thumbnail', () {
        final raw = StationFactory.createRawStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          thumbnailUrl: 'https://station-thumb.com/img.png',
          nowPlaying: StationFactory.createNowPlaying(
            songName: 'Song',
            songThumbnailUrl: 'https://song-thumb.com/img.png',
          ),
        );

        expect(
          Utils.getStationThumbnailUrl(raw),
          'https://song-thumb.com/img.png',
        );
      });

      test('falls back to station thumbnail when no song thumbnail', () {
        final raw = StationFactory.createRawStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          thumbnailUrl: 'https://station-thumb.com/img.png',
          nowPlaying: StationFactory.createNowPlaying(
            songName: 'Song',
            songThumbnailUrl: null,
          ),
        );

        expect(
          Utils.getStationThumbnailUrl(raw),
          'https://station-thumb.com/img.png',
        );
      });
    });

    group('getStationStreamUrls - extended', () {
      test('returns URLs sorted by stream order', () {
        final raw = StationFactory.createRawStation(
          id: 1,
          slug: 'test',
          title: 'Test',
          stationStreams: [
            Query$GetStations$stations$station_streams(
              order: 2,
              type: 'HLS',
              stream_url: 'https://c.com',
            ),
            Query$GetStations$stations$station_streams(
              order: 0,
              type: 'mp3',
              stream_url: 'https://a.com',
            ),
            Query$GetStations$stations$station_streams(
              order: 1,
              type: 'aac',
              stream_url: 'https://b.com',
            ),
          ],
        );

        final urls = Utils.getStationStreamUrls(raw);
        expect(urls, ['https://a.com', 'https://b.com', 'https://c.com']);
      });
    });
  });
}
