import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/types/playlist_item.dart';

import 'helpers/station_factory.dart';

void main() {
  group('StationMediaType.parse', () {
    test('defaults to radio when null or missing', () {
      expect(StationMediaType.parse(null), StationMediaType.radio);
    });

    test('parses case-insensitively', () {
      expect(StationMediaType.parse('tv'), StationMediaType.tv);
      expect(StationMediaType.parse('TV'), StationMediaType.tv);
      expect(StationMediaType.parse('  Tv '), StationMediaType.tv);
      expect(StationMediaType.parse('playlist'), StationMediaType.playlist);
      expect(StationMediaType.parse('PLAYLIST'), StationMediaType.playlist);
      expect(StationMediaType.parse('radio'), StationMediaType.radio);
    });

    test('falls back to radio for unknown values', () {
      expect(StationMediaType.parse('podcast'), StationMediaType.radio);
      expect(StationMediaType.parse(''), StationMediaType.radio);
    });
  });

  group('PlaylistItemType.parse', () {
    test('defaults to audio only when null or empty (legacy items)', () {
      expect(PlaylistItemType.parse(null), PlaylistItemType.audio);
      expect(PlaylistItemType.parse(''), PlaylistItemType.audio);
      expect(PlaylistItemType.parse('   '), PlaylistItemType.audio);
    });

    test('maps an unrecognized non-empty value to unknown (not audio)', () {
      expect(PlaylistItemType.parse('whatever'), PlaylistItemType.unknown);
      expect(PlaylistItemType.parse('podcast'), PlaylistItemType.unknown);
      expect(PlaylistItemType.parse('livestream'), PlaylistItemType.unknown);
    });

    test('parses case-insensitively', () {
      expect(PlaylistItemType.parse('audio'), PlaylistItemType.audio);
      expect(PlaylistItemType.parse('Video'), PlaylistItemType.video);
      expect(PlaylistItemType.parse('YOUTUBE'), PlaylistItemType.youtube);
      expect(PlaylistItemType.parse('youtube_playlist'),
          PlaylistItemType.youtubePlaylist);
      expect(PlaylistItemType.parse('YouTube_Playlist'),
          PlaylistItemType.youtubePlaylist);
      expect(PlaylistItemType.parse('  youtube_playlist '),
          PlaylistItemType.youtubePlaylist);
    });

    test('isYoutube covers single videos and whole playlists only', () {
      expect(PlaylistItemType.youtube.isYoutube, isTrue);
      expect(PlaylistItemType.youtubePlaylist.isYoutube, isTrue);
      expect(PlaylistItemType.audio.isYoutube, isFalse);
      expect(PlaylistItemType.video.isYoutube, isFalse);
      expect(PlaylistItemType.unknown.isYoutube, isFalse);
    });
  });

  group('Station.stationType', () {
    test('defaults to radio when station_type is missing', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'radio-1',
        title: 'Radio One',
      );
      expect(station.stationType, StationMediaType.radio);
      expect(station.isTv, isFalse);
      expect(station.isPlaylist, isFalse);
    });

    test('maps "TV" (any case) to tv', () {
      final station = StationFactory.createStation(
        id: 2,
        slug: 'tv-1',
        title: 'TV One',
        stationType: 'TV',
      );
      expect(station.stationType, StationMediaType.tv);
      expect(station.isTv, isTrue);
      expect(station.isPlaylist, isFalse);
    });

    test('maps "playlist" to playlist', () {
      final station = StationFactory.createStation(
        id: 3,
        slug: 'pl-1',
        title: 'Playlist One',
        stationType: 'playlist',
      );
      expect(station.stationType, StationMediaType.playlist);
      expect(station.isPlaylist, isTrue);
      expect(station.isTv, isFalse);
    });

    test('mediaItem extras carry the station_type name', () {
      final station = StationFactory.createStation(
        id: 4,
        slug: 'tv-2',
        title: 'TV Two',
        stationType: 'tv',
      );
      expect(station.mediaItem.extras!['station_type'], 'tv');
    });
  });

  group('Station.playlistItems', () {
    test('returns empty list when playlist_items is missing', () {
      final station = StationFactory.createStation(
        id: 5,
        slug: 'radio-2',
        title: 'Radio Two',
      );
      expect(station.playlistItems, isEmpty);
    });

    test('maps raw playlist items preserving order', () {
      final station = StationFactory.createStation(
        id: 6,
        slug: 'pl-2',
        title: 'Playlist Two',
        stationType: 'playlist',
        playlistItems: [
          StationFactory.createPlaylistItem(
            id: 10,
            order: 0,
            type: 'audio',
            url: 'https://example.com/a.mp3',
            title: 'First',
            durationSeconds: 120,
          ),
          StationFactory.createPlaylistItem(
            id: 11,
            order: 1,
            type: 'YouTube',
            url: 'https://youtu.be/abc',
            title: 'Second',
            thumbnailUrl: 'https://example.com/thumb.png',
          ),
        ],
      );

      final items = station.playlistItems;
      expect(items.length, 2);

      expect(items[0].id, 10);
      expect(items[0].order, 0);
      expect(items[0].type, PlaylistItemType.audio);
      expect(items[0].url, 'https://example.com/a.mp3');
      expect(items[0].title, 'First');
      expect(items[0].durationSeconds, 120);
      expect(items[0].thumbnailUrl, isNull);

      expect(items[1].id, 11);
      expect(items[1].type, PlaylistItemType.youtube);
      expect(items[1].thumbnailUrl, 'https://example.com/thumb.png');
      expect(items[1].durationSeconds, isNull);
    });

    test('coerces null wire fields to safe defaults', () {
      final station = StationFactory.createStation(
        id: 7,
        slug: 'pl-3',
        title: 'Playlist Three',
        stationType: 'playlist',
        playlistItems: [
          StationFactory.createPlaylistItem(
            id: 20,
            order: null,
            type: null,
            url: null,
            title: null,
          ),
        ],
      );

      final item = station.playlistItems.single;
      expect(item.order, 0);
      expect(item.type, PlaylistItemType.audio);
      expect(item.url, '');
      expect(item.title, '');
    });
  });
}
