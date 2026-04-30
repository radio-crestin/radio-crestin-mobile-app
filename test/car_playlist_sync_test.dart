import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/station_sort_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';

import 'helpers/station_factory.dart';

/// Tests that the playlist order is unified across phone, CarPlay, and Android Auto.
/// The sort algorithms and navigation logic must produce the same results
/// regardless of which surface initiates playback.
void main() {
  group('Unified playlist sort order', () {
    late List<Station> stations;

    setUp(() {
      stations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha Radio', totalListeners: 100, order: 3),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta FM', totalListeners: 50, order: 1),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma Station', totalListeners: 200, order: 2),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta Radio', totalListeners: 10, order: 0),
        StationFactory.createStation(id: 5, slug: 'epsilon', title: 'Epsilon FM', totalListeners: 150, order: 4),
      ];
    });

    test('alphabetical sort produces same order for all platforms', () {
      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.alphabetical,
        playCounts: {},
        favoriteSlugs: [],
      );

      expect(result.sorted.map((s) => s.slug).toList(), [
        'alpha',
        'beta',
        'delta',
        'epsilon',
        'gamma',
      ]);
    });

    test('listeners sort produces same order for all platforms', () {
      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.listeners,
        playCounts: {},
        favoriteSlugs: [],
      );

      // Highest listeners first
      expect(result.sorted.map((s) => s.slug).toList(), [
        'gamma',    // 200
        'epsilon',  // 150
        'alpha',    // 100
        'beta',     // 50
        'delta',    // 10
      ]);
    });

    test('mostPlayed sort with play counts', () {
      final playCounts = {'beta': 10, 'delta': 5, 'gamma': 3};
      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.mostPlayed,
        playCounts: playCounts,
        favoriteSlugs: [],
      );

      // Played stations first (by count), then unplayed by score
      expect(result.sorted[0].slug, 'beta');   // 10 plays
      expect(result.sorted[1].slug, 'delta');  // 5 plays
      expect(result.sorted[2].slug, 'gamma');  // 3 plays
    });

    test('sort is deterministic - same input always produces same output', () {
      final result1 = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.alphabetical,
        playCounts: {},
        favoriteSlugs: [],
      );
      final result2 = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.alphabetical,
        playCounts: {},
        favoriteSlugs: [],
      );

      expect(
        result1.sorted.map((s) => s.slug).toList(),
        result2.sorted.map((s) => s.slug).toList(),
      );
    });
  });

  group('Skip next/prev with sorted playlist', () {
    late List<Station> sortedPlaylist;

    setUp(() {
      // Simulate alphabetically sorted playlist
      sortedPlaylist = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma'),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta'),
      ];
    });

    Station? skipToNext(List<Station> playlist, Station? current) {
      if (current == null || playlist.isEmpty) return null;
      final idx = playlist.indexWhere((s) => s.slug == current.slug);
      final nextIdx = (idx + 1) % playlist.length;
      return playlist[nextIdx < 0 ? 0 : nextIdx];
    }

    Station? skipToPrevious(List<Station> playlist, Station? current) {
      if (current == null || playlist.isEmpty) return null;
      final idx = playlist.indexWhere((s) => s.slug == current.slug);
      final prevIdx = idx <= 0 ? playlist.length - 1 : idx - 1;
      return playlist[prevIdx];
    }

    test('next follows sorted order regardless of source', () {
      // Simulates: user is on "Alpha", presses next from phone/CarPlay/Android Auto
      final current = sortedPlaylist[0]; // Alpha
      final next = skipToNext(sortedPlaylist, current);
      expect(next!.slug, 'beta');
    });

    test('previous follows sorted order regardless of source', () {
      final current = sortedPlaylist[1]; // Beta
      final prev = skipToPrevious(sortedPlaylist, current);
      expect(prev!.slug, 'alpha');
    });

    test('full cycle through sorted playlist is consistent', () {
      Station current = sortedPlaylist[0];
      final visited = <String>[];

      for (int i = 0; i < sortedPlaylist.length; i++) {
        visited.add(current.slug);
        current = skipToNext(sortedPlaylist, current)!;
      }

      expect(visited, sortedPlaylist.map((s) => s.slug).toList());
      // After full cycle, we're back at start
      expect(current.slug, sortedPlaylist[0].slug);
    });
  });

  group('Favorites playlist navigation', () {
    late List<Station> allStations;
    late List<String> favoriteSlugs;

    setUp(() {
      allStations = [
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha', order: 0),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta', order: 1),
        StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma', order: 2),
        StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta', order: 3),
        StationFactory.createStation(id: 5, slug: 'epsilon', title: 'Epsilon', order: 4),
      ];
      favoriteSlugs = ['alpha', 'gamma', 'epsilon'];
    });

    test('skip next only navigates within favorites when in favorites mode', () {
      final favPlaylist = allStations
          .where((s) => favoriteSlugs.contains(s.slug))
          .toList();

      expect(favPlaylist.length, 3);

      // Starting at alpha, next should be gamma (skipping beta which is not favorite)
      final current = favPlaylist[0]; // alpha
      final idx = favPlaylist.indexWhere((s) => s.slug == current.slug);
      final nextIdx = (idx + 1) % favPlaylist.length;
      final next = favPlaylist[nextIdx];

      expect(next.slug, 'gamma');
    });

    test('favorites playlist wraps correctly', () {
      final favPlaylist = allStations
          .where((s) => favoriteSlugs.contains(s.slug))
          .toList();

      // At epsilon (last favorite), next should wrap to alpha
      final current = favPlaylist[2]; // epsilon
      final idx = favPlaylist.indexWhere((s) => s.slug == current.slug);
      final nextIdx = (idx + 1) % favPlaylist.length;
      final next = favPlaylist[nextIdx];

      expect(next.slug, 'alpha');
    });

    test('removing a favorite updates the navigation order', () {
      // Remove gamma from favorites
      favoriteSlugs = ['alpha', 'epsilon'];
      final favPlaylist = allStations
          .where((s) => favoriteSlugs.contains(s.slug))
          .toList();

      // Now alpha -> epsilon directly
      final current = favPlaylist[0]; // alpha
      final idx = favPlaylist.indexWhere((s) => s.slug == current.slug);
      final nextIdx = (idx + 1) % favPlaylist.length;
      final next = favPlaylist[nextIdx];

      expect(next.slug, 'epsilon');
    });
  });

  group('Play state tracking', () {
    test('isPlaying must consider both slug match AND playing state', () {
      // This tests the logic used in _updateCarPlayListPlayingState
      const currentSlug = 'alpha';
      const isPlaying = false; // paused

      final items = ['alpha', 'beta', 'gamma'];
      final states = items.map((slug) => slug == currentSlug && isPlaying).toList();

      // Even though alpha is the current station, isPlaying should be false
      expect(states[0], false); // alpha - current but paused
      expect(states[1], false); // beta
      expect(states[2], false); // gamma
    });

    test('isPlaying true only when slug matches AND playing', () {
      const currentSlug = 'beta';
      const isPlaying = true;

      final items = ['alpha', 'beta', 'gamma'];
      final states = items.map((slug) => slug == currentSlug && isPlaying).toList();

      expect(states[0], false); // alpha
      expect(states[1], true);  // beta - current and playing
      expect(states[2], false); // gamma
    });
  });

  group('Recommended ("Pour tine") sort order for skip next/prev', () {
    late List<Station> stations;

    setUp(() {
      // Stations with varying listeners and play counts to test recommended sort
      stations = [
        StationFactory.createStation(id: 1, slug: 'radio-a', title: 'Radio A', totalListeners: 50, order: 0),
        StationFactory.createStation(id: 2, slug: 'radio-b', title: 'Radio B', totalListeners: 200, order: 1),
        StationFactory.createStation(id: 3, slug: 'radio-c', title: 'Radio C', totalListeners: 10, order: 2),
        StationFactory.createStation(id: 4, slug: 'radio-d', title: 'Radio D', totalListeners: 150, order: 3),
        StationFactory.createStation(id: 5, slug: 'radio-e', title: 'Radio E', totalListeners: 80, order: 4),
        StationFactory.createStation(id: 6, slug: 'radio-f', title: 'Radio F', totalListeners: 300, order: 5),
      ];
    });

    Station? skipToNext(List<Station> playlist, Station? current) {
      if (current == null || playlist.isEmpty) return null;
      final idx = playlist.indexWhere((s) => s.slug == current.slug);
      final nextIdx = (idx + 1) % playlist.length;
      return playlist[nextIdx < 0 ? 0 : nextIdx];
    }

    Station? skipToPrevious(List<Station> playlist, Station? current) {
      if (current == null || playlist.isEmpty) return null;
      final idx = playlist.indexWhere((s) => s.slug == current.slug);
      final prevIdx = idx <= 0 ? playlist.length - 1 : idx - 1;
      return playlist[prevIdx];
    }

    test('recommended sort places station of the day first', () {
      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: {},
        favoriteSlugs: [],
      );

      // Station of the day is deterministic based on day of year
      expect(result.stationOfDaySlug, isNotNull);
      expect(result.sorted.first.slug, result.stationOfDaySlug);
    });

    test('skip next follows recommended sort order, not DB order', () {
      final playCounts = {'radio-c': 20, 'radio-a': 15, 'radio-e': 10};
      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: playCounts,
        favoriteSlugs: [],
      );
      final sorted = result.sorted;

      // The order should NOT be radio-a, radio-b, radio-c, ... (DB order)
      // It should follow the recommended algorithm
      expect(sorted.map((s) => s.slug).toList(), isNot(equals(
        stations.map((s) => s.slug).toList(),
      )));

      // Verify skip next follows the recommended order exactly
      for (int i = 0; i < sorted.length - 1; i++) {
        final next = skipToNext(sorted, sorted[i]);
        expect(next!.slug, sorted[i + 1].slug,
          reason: 'From ${sorted[i].slug}, next should be ${sorted[i + 1].slug}');
      }
    });

    test('skip prev follows recommended sort order backwards', () {
      final playCounts = {'radio-c': 20, 'radio-a': 15, 'radio-e': 10};
      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: playCounts,
        favoriteSlugs: [],
      );
      final sorted = result.sorted;

      // Verify skip previous follows the recommended order backwards
      for (int i = sorted.length - 1; i > 0; i--) {
        final prev = skipToPrevious(sorted, sorted[i]);
        expect(prev!.slug, sorted[i - 1].slug,
          reason: 'From ${sorted[i].slug}, prev should be ${sorted[i - 1].slug}');
      }
    });

    test('recommended sort puts top-played stations into mostPlayedSlugs', () {
      final playCounts = {'radio-c': 50, 'radio-e': 30, 'radio-a': 20};
      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: playCounts,
        favoriteSlugs: [],
      );

      // _sortRecommended fills positions 2-4. Station of the day (position 1)
      // rotates daily, so it may itself be one of the top-played slugs — in
      // which case it's removed from mostPlayedSlugs and the slot is back-
      // filled by score. The invariant: every top-played slug that ISN'T the
      // station of the day must end up in mostPlayedSlugs.
      expect(result.mostPlayedSlugs.length, 3);
      final expectedFromPlayCounts = playCounts.keys
          .where((slug) => slug != result.stationOfDaySlug)
          .toSet();
      expect(result.mostPlayedSlugs, containsAll(expectedFromPlayCounts));
    });

    test('full round-trip through recommended order returns to start', () {
      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: {'radio-b': 5},
        favoriteSlugs: [],
      );
      final sorted = result.sorted;

      Station current = sorted.first;
      for (int i = 0; i < sorted.length; i++) {
        current = skipToNext(sorted, current)!;
      }
      // After cycling through all stations, we're back at the start
      expect(current.slug, sorted.first.slug);
    });

    test('favorites within recommended sort maintain recommended order', () {
      final playCounts = {'radio-c': 50, 'radio-e': 30};
      final favoriteSlugs = ['radio-b', 'radio-d', 'radio-f'];

      // Sort all stations with recommended algorithm
      final result = StationSortService.sort(
        stations: stations,
        sortBy: StationSortOption.recommended,
        playCounts: playCounts,
        favoriteSlugs: favoriteSlugs,
      );
      final sorted = result.sorted;

      // Filter to just favorites, preserving recommended order
      final favoritesInRecommendedOrder = sorted
          .where((s) => favoriteSlugs.contains(s.slug))
          .toList();

      // Skip next through favorites should follow recommended order
      for (int i = 0; i < favoritesInRecommendedOrder.length - 1; i++) {
        final next = skipToNext(favoritesInRecommendedOrder, favoritesInRecommendedOrder[i]);
        expect(next!.slug, favoritesInRecommendedOrder[i + 1].slug,
          reason: 'Favorites next from ${favoritesInRecommendedOrder[i].slug} should be ${favoritesInRecommendedOrder[i + 1].slug}');
      }
    });

    test('all sort modes produce consistent skip order', () {
      final playCounts = {'radio-c': 50, 'radio-a': 20};

      for (final sortOption in StationSortOption.values) {
        final result = StationSortService.sort(
          stations: stations,
          sortBy: sortOption,
          playCounts: playCounts,
          favoriteSlugs: [],
        );
        final sorted = result.sorted;

        // Every sort mode must include all stations
        expect(sorted.length, stations.length,
          reason: '$sortOption should include all stations');

        // Every sort mode must produce a valid skip cycle
        Station current = sorted.first;
        final visited = <String>{};
        for (int i = 0; i < sorted.length; i++) {
          visited.add(current.slug);
          current = skipToNext(sorted, current)!;
        }
        expect(visited.length, stations.length,
          reason: '$sortOption skip cycle should visit all stations exactly once');
        expect(current.slug, sorted.first.slug,
          reason: '$sortOption skip cycle should return to start');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // CarPlay sync tests
  //
  // These test the sync logic used by CarPlayService without native dependencies.
  // The pattern mirrors CarPlayService exactly: BehaviorSubject streams drive
  // updates to a map of list item states.
  // ---------------------------------------------------------------------------

  group('Phone → CarPlay play state sync', () {
    // Simulates CarPlay list item state: slug → isPlaying
    late Map<String, bool> carPlayItemStates;
    late List<Station> stations;
    late BehaviorSubject<Station?> currentStation;
    late BehaviorSubject<PlaybackState> playbackState;
    late List<StreamSubscription> subscriptions;
    late int forceUpdateCallCount;

    /// Mirrors CarPlayService._updateCarPlayListPlayingState
    void updateCarPlayListPlayingState(String currentSlug) {
      final isPlaying = playbackState.value.playing;
      for (final slug in carPlayItemStates.keys) {
        carPlayItemStates[slug] = slug == currentSlug && isPlaying;
      }
      forceUpdateCallCount++;
    }

    setUp(() {
      stations = StationFactory.createPlaylist(count: 4);
      carPlayItemStates = {for (final s in stations) s.slug: false};
      currentStation = BehaviorSubject<Station?>.seeded(null);
      playbackState = BehaviorSubject<PlaybackState>.seeded(
        PlaybackState(playing: false, processingState: AudioProcessingState.idle),
      );
      subscriptions = [];
      forceUpdateCallCount = 0;

      // Mirror CarPlayService subscriptions
      subscriptions.add(currentStation.stream.listen((station) {
        if (station != null) {
          updateCarPlayListPlayingState(station.slug);
        }
      }));
      subscriptions.add(playbackState.stream.listen((_) {
        final slug = currentStation.value?.slug;
        if (slug != null) {
          updateCarPlayListPlayingState(slug);
        }
      }));
    });

    tearDown(() {
      for (final sub in subscriptions) {
        sub.cancel();
      }
      currentStation.close();
      playbackState.close();
    });

    test('selecting a station on phone marks it playing in CarPlay', () async {
      currentStation.add(stations[1]);
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero); // let streams propagate

      expect(carPlayItemStates['station-1'], false);
      expect(carPlayItemStates['station-2'], true);
      expect(carPlayItemStates['station-3'], false);
      expect(carPlayItemStates['station-4'], false);
    });

    test('pausing on phone clears playing state in CarPlay', () async {
      currentStation.add(stations[0]);
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-1'], true);

      // Pause
      playbackState.add(PlaybackState(playing: false, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);

      expect(carPlayItemStates['station-1'], false);
      expect(carPlayItemStates.values.every((v) => v == false), true,
        reason: 'All items should be not-playing when paused');
    });

    test('resuming on phone restores playing state in CarPlay', () async {
      currentStation.add(stations[2]);
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-3'], true);

      // Pause then resume
      playbackState.add(PlaybackState(playing: false, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-3'], false);

      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-3'], true);
    });

    test('switching station on phone moves playing indicator', () async {
      currentStation.add(stations[0]);
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-1'], true);
      expect(carPlayItemStates['station-3'], false);

      // Switch to station-3
      currentStation.add(stations[2]);
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-1'], false);
      expect(carPlayItemStates['station-3'], true);
    });

    test('forceUpdateRootTemplate is called on every state change', () async {
      final initialCount = forceUpdateCallCount;
      currentStation.add(stations[0]);
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);

      expect(forceUpdateCallCount, greaterThan(initialCount),
        reason: 'forceUpdateRootTemplate must be called to make CarPlay redraw');
    });

    test('rapid station changes produce correct final state', () async {
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      // Simulate rapid tapping through stations
      currentStation.add(stations[0]);
      currentStation.add(stations[1]);
      currentStation.add(stations[2]);
      currentStation.add(stations[3]);
      await Future.delayed(Duration.zero);

      // Only the last station should be playing
      expect(carPlayItemStates['station-1'], false);
      expect(carPlayItemStates['station-2'], false);
      expect(carPlayItemStates['station-3'], false);
      expect(carPlayItemStates['station-4'], true);
    });
  });

  group('Phone → CarPlay favorite sync', () {
    late Map<String, String> carPlayItemTexts; // slug → display text
    late List<String> carPlayFavoriteTabSlugs; // slugs visible in favorite tab
    late List<Station> stations;
    late BehaviorSubject<List<String>> favoriteStationSlugs;
    late BehaviorSubject<Station?> currentStation;
    late List<StreamSubscription> subscriptions;
    late int forceUpdateCallCount;
    late bool nowPlayingFavoriteState;

    /// Mirrors CarPlayService._updateCarPlayFavorites
    void updateCarPlayFavorites() {
      final favSlugs = favoriteStationSlugs.value;

      // Update star prefix in "all stations" items
      for (final station in stations) {
        final isFav = favSlugs.contains(station.slug);
        carPlayItemTexts[station.slug] = isFav ? '★ ${station.title}' : station.title;
      }

      // Rebuild favorite tab contents
      carPlayFavoriteTabSlugs = stations
          .where((s) => favSlugs.contains(s.slug))
          .map((s) => s.slug as String)
          .toList();

      forceUpdateCallCount++;
    }

    /// Mirrors CarPlayService._updateNowPlayingFavoriteState
    void updateNowPlayingFavoriteState(bool isFavorite) {
      nowPlayingFavoriteState = isFavorite;
    }

    setUp(() {
      stations = StationFactory.createPlaylist(count: 5);
      carPlayItemTexts = {for (final s in stations) s.slug: s.title};
      carPlayFavoriteTabSlugs = [];
      favoriteStationSlugs = BehaviorSubject<List<String>>.seeded([]);
      currentStation = BehaviorSubject<Station?>.seeded(null);
      subscriptions = [];
      forceUpdateCallCount = 0;
      nowPlayingFavoriteState = false;

      // Mirror CarPlayService._favoritesSubscription
      subscriptions.add(favoriteStationSlugs.stream.listen((_) {
        final current = currentStation.value;
        if (current != null) {
          updateNowPlayingFavoriteState(
            favoriteStationSlugs.value.contains(current.slug),
          );
        }
        updateCarPlayFavorites();
      }));
    });

    tearDown(() {
      for (final sub in subscriptions) {
        sub.cancel();
      }
      favoriteStationSlugs.close();
      currentStation.close();
    });

    test('adding favorite on phone updates CarPlay star prefix', () async {
      favoriteStationSlugs.add(['station-2']);
      await Future.delayed(Duration.zero);

      expect(carPlayItemTexts['station-1'], 'Station 1'); // no star
      expect(carPlayItemTexts['station-2'], '★ Station 2'); // star added
      expect(carPlayItemTexts['station-3'], 'Station 3'); // no star
    });

    test('adding favorite on phone adds station to CarPlay favorites tab', () async {
      favoriteStationSlugs.add(['station-1', 'station-3']);
      await Future.delayed(Duration.zero);

      expect(carPlayFavoriteTabSlugs, ['station-1', 'station-3']);
    });

    test('removing favorite on phone removes star and updates favorites tab', () async {
      favoriteStationSlugs.add(['station-1', 'station-2', 'station-3']);
      await Future.delayed(Duration.zero);
      expect(carPlayFavoriteTabSlugs.length, 3);
      expect(carPlayItemTexts['station-2'], '★ Station 2');

      // Remove station-2 from favorites
      favoriteStationSlugs.add(['station-1', 'station-3']);
      await Future.delayed(Duration.zero);

      expect(carPlayItemTexts['station-2'], 'Station 2'); // star removed
      expect(carPlayFavoriteTabSlugs, ['station-1', 'station-3']);
      expect(carPlayFavoriteTabSlugs.contains('station-2'), false);
    });

    test('favoriting currently playing station updates Now Playing button', () async {
      currentStation.add(stations[2]); // station-3

      favoriteStationSlugs.add(['station-3']);
      await Future.delayed(Duration.zero);

      expect(nowPlayingFavoriteState, true);
    });

    test('unfavoriting currently playing station updates Now Playing button', () async {
      currentStation.add(stations[2]); // station-3

      favoriteStationSlugs.add(['station-3']);
      await Future.delayed(Duration.zero);
      expect(nowPlayingFavoriteState, true);

      favoriteStationSlugs.add([]);
      await Future.delayed(Duration.zero);
      expect(nowPlayingFavoriteState, false);
    });

    test('favoriting non-playing station does not affect Now Playing button', () async {
      currentStation.add(stations[0]); // station-1

      favoriteStationSlugs.add(['station-3']); // not the playing station
      await Future.delayed(Duration.zero);

      expect(nowPlayingFavoriteState, false,
        reason: 'Now Playing button should reflect current station, not the one just favorited');
    });

    test('forceUpdateRootTemplate called on every favorite change', () async {
      final initialCount = forceUpdateCallCount;

      favoriteStationSlugs.add(['station-1']);
      await Future.delayed(Duration.zero);
      expect(forceUpdateCallCount, greaterThan(initialCount));

      final afterFirst = forceUpdateCallCount;
      favoriteStationSlugs.add(['station-1', 'station-2']);
      await Future.delayed(Duration.zero);
      expect(forceUpdateCallCount, greaterThan(afterFirst));
    });

    test('empty favorites list clears CarPlay favorites tab', () async {
      favoriteStationSlugs.add(['station-1', 'station-2']);
      await Future.delayed(Duration.zero);
      expect(carPlayFavoriteTabSlugs.length, 2);

      favoriteStationSlugs.add([]);
      await Future.delayed(Duration.zero);
      expect(carPlayFavoriteTabSlugs, isEmpty);
    });

    test('favorites tab order follows station sort order', () async {
      // Favorites should appear in the same order as the sorted station list
      favoriteStationSlugs.add(['station-4', 'station-1', 'station-3']);
      await Future.delayed(Duration.zero);

      // stations list is in order: station-1, station-2, station-3, station-4, station-5
      // So favorites tab should be: station-1, station-3, station-4 (preserving list order)
      expect(carPlayFavoriteTabSlugs, ['station-1', 'station-3', 'station-4']);
    });
  });

  group('Phone → CarPlay metadata sync', () {
    late Map<String, String> carPlayItemDetailTexts; // slug → detail text
    late List<Station> stations;
    late BehaviorSubject<List<Station>> stationsStream;
    late List<StreamSubscription> subscriptions;
    late int forceUpdateCallCount;

    /// Mirrors CarPlayService._updateCarPlayStationMetadata
    void updateCarPlayStationMetadata(List<Station> updatedStations) {
      for (final station in updatedStations) {
        if (carPlayItemDetailTexts.containsKey(station.slug)) {
          carPlayItemDetailTexts[station.slug] = station.displaySubtitle;
        }
      }
      forceUpdateCallCount++;
    }

    setUp(() {
      stations = [
        StationFactory.createStation(
          id: 1, slug: 'station-1', title: 'Station 1',
          nowPlaying: StationFactory.createNowPlaying(songName: 'Song A', artistName: 'Artist A'),
        ),
        StationFactory.createStation(
          id: 2, slug: 'station-2', title: 'Station 2',
          nowPlaying: StationFactory.createNowPlaying(songName: 'Song B', artistName: 'Artist B'),
        ),
      ];
      carPlayItemDetailTexts = {for (final s in stations) s.slug: s.displaySubtitle};
      stationsStream = BehaviorSubject<List<Station>>.seeded(stations);
      subscriptions = [];
      forceUpdateCallCount = 0;

      // Mirror CarPlayService._carPlayStationsSubscription
      subscriptions.add(stationsStream.stream.skip(1).listen((updated) {
        updateCarPlayStationMetadata(updated);
      }));
    });

    tearDown(() {
      for (final sub in subscriptions) {
        sub.cancel();
      }
      stationsStream.close();
    });

    test('song change from metadata poll updates CarPlay detail text', () async {
      final updatedStations = [
        StationFactory.createStation(
          id: 1, slug: 'station-1', title: 'Station 1',
          nowPlaying: StationFactory.createNowPlaying(songName: 'New Song', artistName: 'New Artist'),
        ),
        stations[1],
      ];

      stationsStream.add(updatedStations);
      await Future.delayed(Duration.zero);

      expect(carPlayItemDetailTexts['station-1'], contains('New Song'));
      // station-2 unchanged
      expect(carPlayItemDetailTexts['station-2'], contains('Song B'));
    });

    test('forceUpdateRootTemplate called after metadata update', () async {
      stationsStream.add(stations);
      await Future.delayed(Duration.zero);
      expect(forceUpdateCallCount, greaterThan(0));
    });
  });
}
