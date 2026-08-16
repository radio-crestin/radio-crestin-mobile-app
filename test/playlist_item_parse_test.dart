import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/playlist_sync_service.dart';
import 'package:radio_crestin/types/playlist_item.dart';

void main() {
  group('PlaylistItem.fromJson', () {
    test('maps all fields from the REST shape', () {
      final item = PlaylistItem.fromJson({
        'id': 7,
        'order': 3,
        'type': 'video',
        'url': 'https://cdn/7.mp4',
        'title': 'Sermon 7',
        'thumbnail_url': 'https://cdn/7.jpg',
        'duration_seconds': 1800,
      });
      expect(item.id, 7);
      expect(item.order, 3);
      expect(item.type, PlaylistItemType.video);
      expect(item.url, 'https://cdn/7.mp4');
      expect(item.title, 'Sermon 7');
      expect(item.thumbnailUrl, 'https://cdn/7.jpg');
      expect(item.durationSeconds, 1800);
    });

    test('applies safe defaults for missing fields', () {
      final item = PlaylistItem.fromJson({'id': 1});
      expect(item.id, 1);
      expect(item.order, 0);
      expect(item.type, PlaylistItemType.audio); // missing type → audio (legacy)
      expect(item.url, '');
      expect(item.title, '');
      expect(item.thumbnailUrl, isNull);
      expect(item.durationSeconds, isNull);
    });

    test('parses youtube type', () {
      final item = PlaylistItem.fromJson({'id': 2, 'type': 'youtube'});
      expect(item.type, PlaylistItemType.youtube);
    });

    test('parses youtube_playlist type', () {
      final item = PlaylistItem.fromJson({'id': 3, 'type': 'youtube_playlist'});
      expect(item.type, PlaylistItemType.youtubePlaylist);
    });

    test('maps an unrecognized future type to unknown (never audio)', () {
      final item = PlaylistItem.fromJson({'id': 4, 'type': 'hologram'});
      expect(item.type, PlaylistItemType.unknown);
    });
  });

  group('PlaylistSyncService.parsePlaylistResponse', () {
    String body(List<Map<String, dynamic>> stations) =>
        json.encode({'data': {'stations': stations}});

    test('preserves the server order exactly (no client re-sort)', () {
      // The server serves items newest-first; the app must not reshuffle them
      // by `order` (that would flip the list on the first poll and disagree
      // with the initial GraphQL load, which also preserves wire order).
      final items = PlaylistSyncService.parsePlaylistResponse(
        body([
          {
            'id': 1,
            'slug': 'devotional',
            'station_type': 'playlist',
            'playlist_items': [
              {'id': 20, 'order': 2, 'type': 'audio', 'url': 'b'},
              {'id': 10, 'order': 1, 'type': 'audio', 'url': 'a'},
            ],
          }
        ]),
      );
      expect(items, isNotNull);
      expect(items!.map((e) => e.id), [20, 10]); // wire order preserved as-is
    });

    test('empty stations array yields empty list', () {
      final items = PlaylistSyncService.parsePlaylistResponse(body([]));
      expect(items, isEmpty);
    });

    test('station without playlist_items yields empty list', () {
      final items = PlaylistSyncService.parsePlaylistResponse(
        body([
          {'id': 1, 'slug': 'x', 'station_type': 'playlist'}
        ]),
      );
      expect(items, isEmpty);
    });

    test('malformed body returns null (keep last known list)', () {
      expect(PlaylistSyncService.parsePlaylistResponse('not json'), isNull);
      expect(PlaylistSyncService.parsePlaylistResponse('{"data":{}}'), isNull);
    });

    test('prefers the station matching the requested slug', () {
      final items = PlaylistSyncService.parsePlaylistResponse(
        body([
          {
            'id': 1,
            'slug': 'other',
            'playlist_items': [
              {'id': 99, 'order': 1, 'type': 'audio', 'url': 'z'}
            ],
          },
          {
            'id': 2,
            'slug': 'wanted',
            'playlist_items': [
              {'id': 42, 'order': 1, 'type': 'audio', 'url': 'w'}
            ],
          },
        ]),
        stationSlug: 'wanted',
      );
      expect(items!.single.id, 42);
    });
  });

  group('playlistItemDisplayName', () {
    PlaylistItem item({String title = '', String url = ''}) => PlaylistItem(
        id: 1, order: 0, type: PlaylistItemType.audio, url: url, title: title);

    test('uses the title when present', () {
      expect(
          playlistItemDisplayName(
              item(title: 'Cântare', url: 'https://x.ro/a.mp3')),
          'Cântare');
    });

    test('falls back to the URL host when the title is empty', () {
      expect(
          playlistItemDisplayName(item(url: 'https://cdn.example.ro/a.mp3')),
          'cdn.example.ro');
      expect(playlistItemDisplayName(item(title: '   ', url: 'https://x.ro/a')),
          'x.ro');
    });

    test('never returns an empty string', () {
      expect(playlistItemDisplayName(item()), isNotEmpty);
      expect(playlistItemDisplayName(item(url: 'not a url')), isNotEmpty);
    });
  });

  group('PlaylistItem.publishedAt parsing', () {
    test('is null when the backend sends no date', () {
      final it = PlaylistItem.fromJson({'id': 1});
      expect(it.publishedAt, isNull);
    });

    test('parses an ISO-8601 published_at (UTC)', () {
      final it = PlaylistItem.fromJson({
        'id': 1,
        'published_at': '2024-08-03T18:30:00Z',
      });
      expect(it.publishedAt, isNotNull);
      final utc = it.publishedAt!.toUtc();
      expect(utc.year, 2024);
      expect(utc.month, 8);
      expect(utc.day, 3);
    });

    test('accepts the alternate "published" key', () {
      final it = PlaylistItem.fromJson({
        'id': 1,
        'published': '2023-01-15T00:00:00Z',
      });
      expect(it.publishedAt!.toUtc().year, 2023);
    });

    test('parses a unix epoch in seconds and in milliseconds', () {
      // 2021-01-01T00:00:00Z = 1609459200 s
      final secs = PlaylistItem.fromJson(
          {'id': 1, 'published_at': 1609459200});
      expect(secs.publishedAt!.toUtc().year, 2021);
      final millis = PlaylistItem.fromJson(
          {'id': 1, 'published_at': 1609459200000});
      expect(millis.publishedAt!.toUtc().year, 2021);
    });

    test('is null for a blank or unparseable value', () {
      expect(PlaylistItem.fromJson({'id': 1, 'published_at': '  '}).publishedAt,
          isNull);
      expect(
          PlaylistItem.fromJson({'id': 1, 'published_at': 'not-a-date'})
              .publishedAt,
          isNull);
    });
  });

  group('formatPlaylistDate', () {
    test('formats as a Romanian long date', () {
      expect(formatPlaylistDate(DateTime(2024, 8, 3)), '3 august 2024');
      expect(formatPlaylistDate(DateTime(2023, 1, 15)), '15 ianuarie 2023');
      expect(formatPlaylistDate(DateTime(2022, 12, 31)), '31 decembrie 2022');
    });
  });
}
