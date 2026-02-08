import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// Tests the station navigation (skip next/previous) logic.
/// Since AppAudioHandler requires platform initialization, we test
/// the navigation algorithm directly.
void main() {
  group('Station navigation - skip to next', () {
    late List<Station> playlist;

    setUp(() {
      playlist = StationFactory.createPlaylist(count: 5);
    });

    /// Replicates the skipToNext logic from AppAudioHandler
    Station? skipToNext(List<Station> playlist, Station? currentStation) {
      if (currentStation == null) return null;
      if (playlist.isEmpty) return null;

      final currentIndex =
          playlist.indexWhere((s) => s.slug == currentStation.slug);
      final nextIndex = (currentIndex + 1) % playlist.length;
      return playlist[nextIndex < 0 ? 0 : nextIndex];
    }

    test('moves to next station in playlist', () {
      final current = playlist[0]; // station-1
      final next = skipToNext(playlist, current);

      expect(next, isNotNull);
      expect(next!.slug, 'station-2');
    });

    test('wraps around to first station when at end of playlist', () {
      final current = playlist[4]; // station-5 (last)
      final next = skipToNext(playlist, current);

      expect(next, isNotNull);
      expect(next!.slug, 'station-1');
    });

    test('returns null when current station is null', () {
      expect(skipToNext(playlist, null), isNull);
    });

    test('returns null when playlist is empty', () {
      expect(skipToNext([], playlist[0]), isNull);
    });

    test('returns first station when current not found in playlist', () {
      final outsideStation = StationFactory.createStation(
        id: 99,
        slug: 'not-in-playlist',
        title: 'Not In Playlist',
      );
      // indexWhere returns -1, then (-1 + 1) % 5 = 0
      final next = skipToNext(playlist, outsideStation);
      expect(next!.slug, 'station-1');
    });

    test('works with single-station playlist', () {
      final singlePlaylist = [playlist[0]];
      final next = skipToNext(singlePlaylist, playlist[0]);
      expect(next!.slug, 'station-1'); // wraps to itself
    });

    test('navigates through entire playlist sequentially', () {
      Station current = playlist[0];
      final visitedSlugs = <String>[current.slug];

      for (int i = 0; i < playlist.length - 1; i++) {
        current = skipToNext(playlist, current)!;
        visitedSlugs.add(current.slug);
      }

      expect(visitedSlugs, [
        'station-1',
        'station-2',
        'station-3',
        'station-4',
        'station-5',
      ]);
    });
  });

  group('Station navigation - skip to previous', () {
    late List<Station> playlist;

    setUp(() {
      playlist = StationFactory.createPlaylist(count: 5);
    });

    /// Replicates the skipToPrevious logic from AppAudioHandler
    Station? skipToPrevious(List<Station> playlist, Station? currentStation) {
      if (currentStation == null) return null;
      if (playlist.isEmpty) return null;

      final currentIndex =
          playlist.indexWhere((s) => s.slug == currentStation.slug);
      final prevIndex =
          currentIndex <= 0 ? playlist.length - 1 : currentIndex - 1;
      return playlist[prevIndex];
    }

    test('moves to previous station in playlist', () {
      final current = playlist[2]; // station-3
      final prev = skipToPrevious(playlist, current);

      expect(prev, isNotNull);
      expect(prev!.slug, 'station-2');
    });

    test('wraps around to last station when at beginning of playlist', () {
      final current = playlist[0]; // station-1 (first)
      final prev = skipToPrevious(playlist, current);

      expect(prev, isNotNull);
      expect(prev!.slug, 'station-5');
    });

    test('returns null when current station is null', () {
      expect(skipToPrevious(playlist, null), isNull);
    });

    test('returns null when playlist is empty', () {
      expect(skipToPrevious([], playlist[0]), isNull);
    });

    test('wraps to last when current not found in playlist', () {
      final outsideStation = StationFactory.createStation(
        id: 99,
        slug: 'not-in-playlist',
        title: 'Not In Playlist',
      );
      // indexWhere returns -1, which is <= 0, so prevIndex = playlist.length - 1 = 4
      final prev = skipToPrevious(playlist, outsideStation);
      expect(prev!.slug, 'station-5');
    });

    test('works with single-station playlist', () {
      final singlePlaylist = [playlist[0]];
      final prev = skipToPrevious(singlePlaylist, playlist[0]);
      expect(prev!.slug, 'station-1'); // wraps to itself
    });

    test('navigates backwards through entire playlist', () {
      Station current = playlist[0]; // start at first
      final visitedSlugs = <String>[current.slug];

      for (int i = 0; i < playlist.length - 1; i++) {
        current = skipToPrevious(playlist, current)!;
        visitedSlugs.add(current.slug);
      }

      expect(visitedSlugs, [
        'station-1',
        'station-5',
        'station-4',
        'station-3',
        'station-2',
      ]);
    });
  });

  group('Station navigation - next then previous returns to same station', () {
    test('round trip: next then previous returns to original station', () {
      final playlist = StationFactory.createPlaylist(count: 5);
      final original = playlist[2]; // station-3

      // Skip to next
      final currentIndex =
          playlist.indexWhere((s) => s.slug == original.slug);
      final nextIndex = (currentIndex + 1) % playlist.length;
      final afterNext = playlist[nextIndex];

      // Skip to previous from there
      final afterNextIndex =
          playlist.indexWhere((s) => s.slug == afterNext.slug);
      final prevIndex = afterNextIndex <= 0
          ? playlist.length - 1
          : afterNextIndex - 1;
      final afterPrev = playlist[prevIndex];

      expect(afterPrev.slug, original.slug);
    });
  });
}
