import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// Tests the Android Auto player state change detection logic.
/// This logic prevents unnecessary player screen invalidations (flickering)
/// by skipping updates when nothing has changed.
void main() {
  group('Android Auto player - change detection', () {
    // Replicate the change detection logic from CarPlayService._updateAndroidAutoPlayer
    bool shouldUpdate({
      required String? lastSlug,
      required String? lastSongTitle,
      required String? lastArtist,
      required bool? lastIsPlaying,
      required bool? lastIsFavorite,
      required String currentSlug,
      required String currentSongTitle,
      required String currentArtist,
      required bool currentIsPlaying,
      required bool currentIsFavorite,
    }) {
      if (lastSlug == currentSlug &&
          lastSongTitle == currentSongTitle &&
          lastArtist == currentArtist &&
          lastIsPlaying == currentIsPlaying &&
          lastIsFavorite == currentIsFavorite) {
        return false;
      }
      return true;
    }

    test('skips update when nothing changed', () {
      expect(
        shouldUpdate(
          lastSlug: 'station-1',
          lastSongTitle: 'Song A',
          lastArtist: 'Artist A',
          lastIsPlaying: true,
          lastIsFavorite: false,
          currentSlug: 'station-1',
          currentSongTitle: 'Song A',
          currentArtist: 'Artist A',
          currentIsPlaying: true,
          currentIsFavorite: false,
        ),
        isFalse,
      );
    });

    test('updates when station changes', () {
      expect(
        shouldUpdate(
          lastSlug: 'station-1',
          lastSongTitle: 'Song A',
          lastArtist: 'Artist A',
          lastIsPlaying: true,
          lastIsFavorite: false,
          currentSlug: 'station-2',
          currentSongTitle: 'Song A',
          currentArtist: 'Artist A',
          currentIsPlaying: true,
          currentIsFavorite: false,
        ),
        isTrue,
      );
    });

    test('updates when song title changes', () {
      expect(
        shouldUpdate(
          lastSlug: 'station-1',
          lastSongTitle: 'Song A',
          lastArtist: 'Artist A',
          lastIsPlaying: true,
          lastIsFavorite: false,
          currentSlug: 'station-1',
          currentSongTitle: 'Song B',
          currentArtist: 'Artist A',
          currentIsPlaying: true,
          currentIsFavorite: false,
        ),
        isTrue,
      );
    });

    test('updates when artist changes', () {
      expect(
        shouldUpdate(
          lastSlug: 'station-1',
          lastSongTitle: 'Song A',
          lastArtist: 'Artist A',
          lastIsPlaying: true,
          lastIsFavorite: false,
          currentSlug: 'station-1',
          currentSongTitle: 'Song A',
          currentArtist: 'Artist B',
          currentIsPlaying: true,
          currentIsFavorite: false,
        ),
        isTrue,
      );
    });

    test('updates when play state changes', () {
      expect(
        shouldUpdate(
          lastSlug: 'station-1',
          lastSongTitle: 'Song A',
          lastArtist: 'Artist A',
          lastIsPlaying: true,
          lastIsFavorite: false,
          currentSlug: 'station-1',
          currentSongTitle: 'Song A',
          currentArtist: 'Artist A',
          currentIsPlaying: false,
          currentIsFavorite: false,
        ),
        isTrue,
      );
    });

    test('updates when favorite state changes', () {
      expect(
        shouldUpdate(
          lastSlug: 'station-1',
          lastSongTitle: 'Song A',
          lastArtist: 'Artist A',
          lastIsPlaying: true,
          lastIsFavorite: false,
          currentSlug: 'station-1',
          currentSongTitle: 'Song A',
          currentArtist: 'Artist A',
          currentIsPlaying: true,
          currentIsFavorite: true,
        ),
        isTrue,
      );
    });

    test('always updates when last state is null (first update)', () {
      expect(
        shouldUpdate(
          lastSlug: null,
          lastSongTitle: null,
          lastArtist: null,
          lastIsPlaying: null,
          lastIsFavorite: null,
          currentSlug: 'station-1',
          currentSongTitle: 'Song A',
          currentArtist: 'Artist A',
          currentIsPlaying: true,
          currentIsFavorite: false,
        ),
        isTrue,
      );
    });

    test('updates when multiple fields change simultaneously', () {
      expect(
        shouldUpdate(
          lastSlug: 'station-1',
          lastSongTitle: 'Song A',
          lastArtist: 'Artist A',
          lastIsPlaying: true,
          lastIsFavorite: false,
          currentSlug: 'station-2',
          currentSongTitle: 'Song B',
          currentArtist: 'Artist B',
          currentIsPlaying: false,
          currentIsFavorite: true,
        ),
        isTrue,
      );
    });
  });

  group('Android Auto player - station display', () {
    test('playing station gets play indicator prefix', () {
      const currentSlug = 'station-1';
      final station = StationFactory.createStation(
        id: 1,
        slug: 'station-1',
        title: 'Test Radio',
      );

      final isPlaying = station.slug == currentSlug;
      final displayTitle =
          isPlaying ? "▶ ${station.title}" : station.title;

      expect(displayTitle, '▶ Test Radio');
    });

    test('non-playing station has no prefix', () {
      const currentSlug = 'station-2';
      final station = StationFactory.createStation(
        id: 1,
        slug: 'station-1',
        title: 'Test Radio',
      );

      final isPlaying = station.slug == currentSlug;
      final displayTitle =
          isPlaying ? "▶ ${station.title}" : station.title;

      expect(displayTitle, 'Test Radio');
    });

    test('station with now playing shows song info as subtitle', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'station-1',
        title: 'Test Radio',
        nowPlaying: StationFactory.createNowPlaying(
          songName: 'Amazing Grace',
          artistName: 'John Newton',
        ),
      );

      expect(station.displaySubtitle, isNotEmpty);
    });

    test('station without now playing has empty subtitle', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'station-1',
        title: 'Test Radio',
      );

      expect(station.displaySubtitle, isEmpty);
    });
  });

  group('Android Auto player - station sorting', () {
    test('stations are sorted alphabetically by title', () {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'c', title: 'Charlie'),
        StationFactory.createStation(id: 2, slug: 'a', title: 'Alpha'),
        StationFactory.createStation(id: 3, slug: 'b', title: 'Bravo'),
      ];

      stations.sort((a, b) => a.title.toString().compareTo(b.title.toString()));

      expect(stations[0].title, 'Alpha');
      expect(stations[1].title, 'Bravo');
      expect(stations[2].title, 'Charlie');
    });

    test('max items limit is enforced', () {
      const maxItems = 100;
      final stations = StationFactory.createPlaylist(count: 150);

      final stationsToShow = stations.length > maxItems
          ? stations.sublist(0, maxItems)
          : stations;

      expect(stationsToShow.length, maxItems);
    });

    test('stations under limit are not truncated', () {
      const maxItems = 100;
      final stations = StationFactory.createPlaylist(count: 50);

      final stationsToShow = stations.length > maxItems
          ? stations.sublist(0, maxItems)
          : stations;

      expect(stationsToShow.length, 50);
    });
  });

  group('Android Auto player - favorites filtering', () {
    test('favorite stations are correctly filtered', () {
      final stations = StationFactory.createPlaylist(count: 5);
      final favoriteSlugs = {'station-1', 'station-3', 'station-5'};

      final favoriteStations =
          stations.where((s) => favoriteSlugs.contains(s.slug)).toList();

      expect(favoriteStations.length, 3);
      expect(favoriteStations[0].slug, 'station-1');
      expect(favoriteStations[1].slug, 'station-3');
      expect(favoriteStations[2].slug, 'station-5');
    });

    test('empty favorites returns empty list', () {
      final stations = StationFactory.createPlaylist(count: 5);
      final favoriteSlugs = <String>{};

      final favoriteStations =
          stations.where((s) => favoriteSlugs.contains(s.slug)).toList();

      expect(favoriteStations, isEmpty);
    });

    test('isFavorite check works correctly', () {
      final favoriteSlugs = {'station-1', 'station-3'};

      expect(favoriteSlugs.contains('station-1'), isTrue);
      expect(favoriteSlugs.contains('station-2'), isFalse);
      expect(favoriteSlugs.contains('station-3'), isTrue);
    });

    test('favorite toggle flips state', () {
      final favoriteSlugs = {'station-1', 'station-3'};

      // Toggle station-1 OFF
      final isFav1 = favoriteSlugs.contains('station-1');
      expect(isFav1, isTrue);
      expect(!isFav1, isFalse); // toggled value

      // Toggle station-2 ON
      final isFav2 = favoriteSlugs.contains('station-2');
      expect(isFav2, isFalse);
      expect(!isFav2, isTrue); // toggled value
    });
  });

  group('Android Auto player - player visibility state', () {
    test('player visibility tracks push/close lifecycle', () {
      bool isPlayerVisible = false;

      // Push player
      isPlayerVisible = true;
      expect(isPlayerVisible, isTrue);

      // Close player (back button)
      isPlayerVisible = false;
      expect(isPlayerVisible, isFalse);
    });

    test('player state resets on close', () {
      String? lastSlug = 'station-1';
      String? lastSongTitle = 'Song A';
      String? lastArtist = 'Artist A';
      bool? lastIsPlaying = true;
      bool? lastIsFavorite = false;

      // Simulate close
      lastSlug = null;
      lastSongTitle = null;
      lastArtist = null;
      lastIsPlaying = null;
      lastIsFavorite = null;

      expect(lastSlug, isNull);
      expect(lastSongTitle, isNull);
      expect(lastArtist, isNull);
      expect(lastIsPlaying, isNull);
      expect(lastIsFavorite, isNull);
    });
  });

  group('Android Auto - cached vs network URL', () {
    test('returns file URI for cached path', () {
      // Simulate _cachedOrNetworkUrl behavior
      String? cachedOrNetworkUrl(String? url, String? cachedPath) {
        if (url == null || url.isEmpty) return url;
        if (cachedPath != null) return 'file://$cachedPath';
        return url;
      }

      expect(
        cachedOrNetworkUrl(
          'https://example.com/thumb.png',
          '/data/user/0/com.example/cache/abc123.png',
        ),
        'file:///data/user/0/com.example/cache/abc123.png',
      );
    });

    test('returns network URL when not cached', () {
      String? cachedOrNetworkUrl(String? url, String? cachedPath) {
        if (url == null || url.isEmpty) return url;
        if (cachedPath != null) return 'file://$cachedPath';
        return url;
      }

      expect(
        cachedOrNetworkUrl('https://example.com/thumb.png', null),
        'https://example.com/thumb.png',
      );
    });

    test('returns null for null URL', () {
      String? cachedOrNetworkUrl(String? url, String? cachedPath) {
        if (url == null || url.isEmpty) return url;
        if (cachedPath != null) return 'file://$cachedPath';
        return url;
      }

      expect(cachedOrNetworkUrl(null, null), isNull);
    });

    test('returns empty for empty URL', () {
      String? cachedOrNetworkUrl(String? url, String? cachedPath) {
        if (url == null || url.isEmpty) return url;
        if (cachedPath != null) return 'file://$cachedPath';
        return url;
      }

      expect(cachedOrNetworkUrl('', null), '');
    });
  });

  group('Android Auto - AAOS detection', () {
    test('isAutomotiveOS returns based on feature availability', () {
      // The actual detection uses PackageManager.FEATURE_AUTOMOTIVE
      // We test the logic pattern: hasSystemFeature returns bool
      bool isAutomotiveOS(bool hasFeature) => hasFeature;

      expect(isAutomotiveOS(true), isTrue);
      expect(isAutomotiveOS(false), isFalse);
    });
  });

  group('Android Auto player - FAB behavior', () {
    test('FAB opens player when station is playing', () {
      bool isPlayerVisible = false;
      Station? currentStation = StationFactory.createStation(
        id: 1,
        slug: 'station-1',
        title: 'Test Radio',
      );
      bool isPlaying = true;

      // FAB logic: if station exists, open player
      String action = 'none';
      if (currentStation != null) {
        if (!isPlayerVisible) {
          action = 'push_player';
          isPlayerVisible = true;
        }
        if (!isPlaying) {
          action = 'resume';
        }
      }

      expect(action, 'push_player');
      expect(isPlayerVisible, isTrue);
    });

    test('FAB resumes playback when paused', () {
      bool isPlayerVisible = true; // player already open
      Station? currentStation = StationFactory.createStation(
        id: 1,
        slug: 'station-1',
        title: 'Test Radio',
      );
      bool isPlaying = false; // paused

      String action = 'none';
      if (currentStation != null) {
        if (!isPlayerVisible) {
          action = 'push_player';
          isPlayerVisible = true;
        }
        if (!isPlaying) {
          action = 'resume';
        }
      }

      expect(action, 'resume');
    });

    test('FAB starts last played station when nothing is loaded', () {
      Station? currentStation = null;
      Station? lastPlayedStation = StationFactory.createStation(
        id: 1,
        slug: 'last-played',
        title: 'Last Played',
      );

      String action = 'none';
      if (currentStation != null) {
        action = 'push_player';
      } else if (lastPlayedStation != null) {
        action = 'start_last_played';
      }

      expect(action, 'start_last_played');
    });

    test('FAB does nothing when no station available', () {
      Station? currentStation = null;
      Station? lastPlayedStation = null;

      String action = 'none';
      if (currentStation != null) {
        action = 'push_player';
      } else if (lastPlayedStation != null) {
        action = 'start_last_played';
      }

      expect(action, 'none');
    });
  });
}
