import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/car_play_service.dart';
import 'package:radio_crestin/services/playlist_reconciler.dart';
import 'package:radio_crestin/types/playlist_item.dart';

import 'helpers/station_factory.dart';

/// Covers CarPlay / Android Auto behavior for the new station types
/// (radio / tv / playlist) and playlist items (audio / video / youtube /
/// youtube_playlist / unknown). Exercises the real pure helpers used by
/// [CarPlayService] plus the real [PlaylistNavigator], so the assertions bind
/// to production code, not a hand-copied replica.
void main() {
  // ── A.1: sensible car-list subtitle for playlist stations ────────────────
  group('CarPlayService.computeStationListSubtitle', () {
    test('radio with a now-playing song keeps the song line', () {
      final result = CarPlayService.computeStationListSubtitle(
        displaySubtitle: 'Amazing Grace • John Newton',
        isPlaylist: false,
        isRomanian: false,
      );
      expect(result, 'Amazing Grace • John Newton');
    });

    test('idle radio (no song) yields null — a blank row, as before', () {
      final result = CarPlayService.computeStationListSubtitle(
        displaySubtitle: '',
        isPlaylist: false,
        isRomanian: false,
      );
      expect(result, isNull);
    });

    test('playlist station (empty song line) falls back to a label, not blank', () {
      expect(
        CarPlayService.computeStationListSubtitle(
          displaySubtitle: '',
          isPlaylist: true,
          isRomanian: false,
        ),
        'Playlist',
      );
      expect(
        CarPlayService.computeStationListSubtitle(
          displaySubtitle: '',
          isPlaylist: true,
          isRomanian: true,
        ),
        'Listă de redare',
      );
    });

    test('real playlist Station gets a non-blank car subtitle', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'pl',
        title: 'Predici',
        stationType: 'playlist',
        playlistItems: [
          StationFactory.createPlaylistItem(id: 1, type: 'audio', title: 'Ep 1'),
        ],
      );
      // A playlist station never has now_playing, so displaySubtitle is empty…
      expect(station.displaySubtitle, isEmpty);
      expect(station.isPlaylist, isTrue);
      // …but the car subtitle must not be blank/misleading.
      final subtitle = CarPlayService.computeStationListSubtitle(
        displaySubtitle: station.displaySubtitle,
        isPlaylist: station.isPlaylist,
        isRomanian: false,
      );
      expect(subtitle, 'Playlist');
    });

    test('real tv Station behaves like radio (song line or null), not a label', () {
      final tvIdle = StationFactory.createStation(
        id: 2,
        slug: 'tv',
        title: 'TV Channel',
        stationType: 'tv',
      );
      expect(tvIdle.isPlaylist, isFalse);
      expect(
        CarPlayService.computeStationListSubtitle(
          displaySubtitle: tvIdle.displaySubtitle,
          isPlaylist: tvIdle.isPlaylist,
          isRomanian: false,
        ),
        isNull,
      );
    });
  });

  // ── A.2: Android Auto player fields carry the playlist item, not the
  //         (empty) station now-playing ────────────────────────────────────
  group('CarPlayService.computePlayerFields', () {
    test('radio mode uses the station now-playing song', () {
      final fields = CarPlayService.computePlayerFields(
        inPlaylistMode: false,
        playlistItemTitle: null,
        playlistItemImageUrl: null,
        stationTitle: 'Radio X',
        stationSongTitle: 'Song A',
        stationSongArtist: 'Artist A',
        stationThumbnailUrl: 'https://x/logo.png',
      );
      expect(fields.songTitle, 'Song A');
      expect(fields.songArtist, 'Artist A');
      expect(fields.imageUrlSource, 'https://x/logo.png');
    });

    test('playlist mode uses the current item title/artwork + station name', () {
      final fields = CarPlayService.computePlayerFields(
        inPlaylistMode: true,
        playlistItemTitle: 'Predica 3',
        playlistItemImageUrl: 'https://x/item3.png',
        stationTitle: 'Predici',
        stationSongTitle: '', // playlist stations have no now-playing song
        stationSongArtist: '',
        stationThumbnailUrl: 'https://x/logo.png',
      );
      expect(fields.songTitle, 'Predica 3');
      expect(fields.songArtist, 'Predici');
      expect(fields.imageUrlSource, 'https://x/item3.png');
    });

    test('playlist item without artwork falls back to the station thumbnail', () {
      final fields = CarPlayService.computePlayerFields(
        inPlaylistMode: true,
        playlistItemTitle: 'Predica 3',
        playlistItemImageUrl: null,
        stationTitle: 'Predici',
        stationSongTitle: '',
        stationSongArtist: '',
        stationThumbnailUrl: 'https://x/logo.png',
      );
      expect(fields.imageUrlSource, 'https://x/logo.png');
    });

    test('playlist mode tolerates a null item title (no crash, empty line)', () {
      final fields = CarPlayService.computePlayerFields(
        inPlaylistMode: true,
        playlistItemTitle: null,
        playlistItemImageUrl: null,
        stationTitle: 'Predici',
        stationSongTitle: '',
        stationSongArtist: '',
        stationThumbnailUrl: null,
      );
      expect(fields.songTitle, '');
      expect(fields.songArtist, 'Predici');
      expect(fields.imageUrlSource, isNull);
    });
  });

  // ── A.3: a youtube-only playlist has nothing to play on a car/cast route —
  //         must fail gracefully (bounded, returns -1), never loop ──────────
  group('PlaylistNavigator in car (skipYoutube = true)', () {
    PlaylistItem item(int id, PlaylistItemType type) => PlaylistItem(
          id: id,
          order: id,
          type: type,
          url: 'https://x/$id',
          title: 'Item $id',
        );

    test('youtube-only playlist yields no playable item in car', () {
      final items = [
        item(1, PlaylistItemType.youtube),
        item(2, PlaylistItemType.youtubePlaylist),
      ];
      final first = PlaylistNavigator.nextPlayableIndex(
        items: items,
        fromIndex: -1,
        skipYoutube: true,
        loop: false,
        direction: 1,
      );
      expect(first, -1);
    });

    test('advance loops are bounded — no infinite loop when nothing plays', () {
      final items = [
        item(1, PlaylistItemType.youtube),
        item(2, PlaylistItemType.unknown),
        item(3, PlaylistItemType.youtubePlaylist),
      ];
      // loop: true is what auto-advance uses; must still terminate at -1.
      final next = PlaylistNavigator.nextPlayableIndex(
        items: items,
        fromIndex: 0,
        skipYoutube: true,
        loop: true,
        direction: 1,
      );
      expect(next, -1);
    });

    test('mixed playlist in car skips youtube and plays the audio item', () {
      final items = [
        item(1, PlaylistItemType.youtube),
        item(2, PlaylistItemType.audio),
        item(3, PlaylistItemType.youtubePlaylist),
      ];
      final first = PlaylistNavigator.nextPlayableIndex(
        items: items,
        fromIndex: -1,
        skipYoutube: true,
        loop: false,
        direction: 1,
      );
      expect(first, 1); // the audio item
    });

    test('same youtube-only playlist DOES play on the phone (skipYoutube false)', () {
      final items = [
        item(1, PlaylistItemType.youtube),
        item(2, PlaylistItemType.youtubePlaylist),
      ];
      final first = PlaylistNavigator.nextPlayableIndex(
        items: items,
        fromIndex: -1,
        skipYoutube: false,
        loop: false,
        direction: 1,
      );
      expect(first, 0);
    });

    test('unknown items are always skipped, even off a car route', () {
      final items = [
        item(1, PlaylistItemType.unknown),
        item(2, PlaylistItemType.audio),
      ];
      final first = PlaylistNavigator.nextPlayableIndex(
        items: items,
        fromIndex: -1,
        skipYoutube: false,
        loop: false,
        direction: 1,
      );
      expect(first, 1);
    });
  });
}
