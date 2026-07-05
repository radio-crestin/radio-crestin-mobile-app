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

    test('parses items sorted by order', () {
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
      expect(items!.map((e) => e.id), [10, 20]); // sorted by order
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
}
