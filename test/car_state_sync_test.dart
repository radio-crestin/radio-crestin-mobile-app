import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';

import 'helpers/station_factory.dart';

/// Tests that prove the Phone → CarPlay / Android Auto play state sync bug
/// and verify the fix.
///
/// ROOT CAUSE:
/// AppAudioHandler._broadcastState was only wired to player.playbackEventStream,
/// which fires on position/buffer changes but does NOT reliably fire on
/// play()/pause() transitions. The player's playingStream fires immediately
/// on state changes but was not listened to, so playbackState (the
/// BehaviorSubject that drives ALL car state subscriptions) could remain
/// stale with playing=false even after the user started playback from phone.
///
/// CarPlay → Phone worked because iOS MPRemoteCommandCenter.playCommand is
/// handled natively by audio_service, updating MPNowPlayingInfoCenter on the
/// native side without going through _broadcastState.
void main() {
  group('Bug proof: playingStream → playbackState → car state', () {
    // These tests simulate the exact scenario where playbackEventStream
    // does NOT fire after player.play(), but playingStream DOES fire.
    // With only playbackEventStream wired, CarPlay/AA never get the update.

    test('BUG: CarPlay stays paused when only playbackEventStream is wired', () async {
      // Simulate the two player streams
      final playingStream = BehaviorSubject<bool>.seeded(false);
      final playbackEventStream = BehaviorSubject<int>.seeded(0); // position events

      // playbackState is what _broadcastState produces
      final playbackState = BehaviorSubject<PlaybackState>.seeded(
        PlaybackState(playing: false, processingState: AudioProcessingState.idle),
      );

      // OLD CODE: only playbackEventStream triggers _broadcastState
      playbackEventStream.listen((_) {
        playbackState.add(playbackState.value.copyWith(playing: playingStream.value));
      });
      // playingStream is NOT listened to (the bug)

      // CarPlay list item state
      bool carPlayIsPlaying = false;
      playbackState.stream.listen((_) {
        carPlayIsPlaying = playbackState.value.playing;
      });

      // Let BehaviorSubject initial replays settle before simulating user action
      await Future.delayed(Duration.zero);
      expect(carPlayIsPlaying, false, reason: 'Initial state is paused');

      // User taps play on phone → playingStream fires, playbackEventStream does NOT
      playingStream.add(true);
      // playbackEventStream does NOT emit a new event (this is the timing issue)
      await Future.delayed(Duration.zero);

      // BUG: CarPlay still shows paused because playbackState was never updated
      // (playbackEventStream didn't fire, so _broadcastState was never called)
      expect(carPlayIsPlaying, false,
          reason: 'Without playingStream listener, CarPlay stays paused');

      playingStream.close();
      playbackEventStream.close();
      playbackState.close();
    });

    test('FIX: CarPlay updates when playingStream is also wired', () async {
      final playingStream = BehaviorSubject<bool>.seeded(false);
      final playbackEventStream = BehaviorSubject<int>.seeded(0);

      final playbackState = BehaviorSubject<PlaybackState>.seeded(
        PlaybackState(playing: false, processingState: AudioProcessingState.idle),
      );

      // OLD: playbackEventStream wired
      playbackEventStream.listen((_) {
        playbackState.add(playbackState.value.copyWith(playing: playingStream.value));
      });

      // FIX: playingStream ALSO wired to _broadcastState
      playingStream.listen((_) {
        playbackState.add(playbackState.value.copyWith(playing: playingStream.value));
      });

      bool carPlayIsPlaying = false;
      playbackState.stream.listen((_) {
        carPlayIsPlaying = playbackState.value.playing;
      });

      // User taps play on phone → playingStream fires, playbackEventStream does NOT
      playingStream.add(true);
      await Future.delayed(Duration.zero);

      // FIX: CarPlay now shows playing because playingStream triggered the update
      expect(carPlayIsPlaying, true,
          reason: 'With playingStream listener, CarPlay updates immediately');

      playingStream.close();
      playbackEventStream.close();
      playbackState.close();
    });

    test('FIX: pause from phone also propagates via playingStream', () async {
      final playingStream = BehaviorSubject<bool>.seeded(true); // already playing
      final playbackState = BehaviorSubject<PlaybackState>.seeded(
        PlaybackState(playing: true, processingState: AudioProcessingState.ready),
      );

      // FIX: playingStream wired
      playingStream.listen((_) {
        playbackState.add(playbackState.value.copyWith(playing: playingStream.value));
      });

      bool carPlayIsPlaying = true;
      playbackState.stream.listen((_) {
        carPlayIsPlaying = playbackState.value.playing;
      });

      // User taps pause on phone
      playingStream.add(false);
      await Future.delayed(Duration.zero);

      expect(carPlayIsPlaying, false,
          reason: 'Pause from phone propagates to CarPlay via playingStream');

      playingStream.close();
      playbackState.close();
    });
  });

  group('Phone → CarPlay list item isPlaying sync', () {
    late Map<String, bool> carPlayItemStates;
    late List<Station> stations;
    late BehaviorSubject<Station?> currentStation;
    late BehaviorSubject<PlaybackState> playbackState;
    late List<StreamSubscription> subscriptions;

    /// Mirrors CarPlayService._updateCarPlayListPlayingState (with optimization)
    void updateCarPlayListPlayingState(String currentSlug) {
      final isPlaying = playbackState.value.playing;
      for (final slug in carPlayItemStates.keys) {
        final shouldBePlaying = slug == currentSlug && isPlaying;
        if (carPlayItemStates[slug] != shouldBePlaying) {
          carPlayItemStates[slug] = shouldBePlaying;
        }
      }
    }

    setUp(() {
      stations = StationFactory.createPlaylist(count: 4);
      carPlayItemStates = {for (final s in stations) s.slug: false};
      currentStation = BehaviorSubject<Station?>.seeded(null);
      playbackState = BehaviorSubject<PlaybackState>.seeded(
        PlaybackState(playing: false, processingState: AudioProcessingState.idle),
      );
      subscriptions = [];

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

    test('phone play marks correct station playing in CarPlay list', () async {
      currentStation.add(stations[1]);
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);

      expect(carPlayItemStates['station-1'], false);
      expect(carPlayItemStates['station-2'], true);
      expect(carPlayItemStates['station-3'], false);
      expect(carPlayItemStates['station-4'], false);
    });

    test('phone pause clears all playing indicators in CarPlay list', () async {
      currentStation.add(stations[0]);
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-1'], true);

      playbackState.add(PlaybackState(playing: false, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);

      expect(carPlayItemStates.values.every((v) => v == false), true);
    });

    test('phone station switch moves playing indicator', () async {
      currentStation.add(stations[0]);
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-1'], true);

      currentStation.add(stations[2]);
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-1'], false);
      expect(carPlayItemStates['station-3'], true);
    });

    test('phone play→pause→play cycle syncs correctly', () async {
      currentStation.add(stations[1]);

      // Play
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-2'], true);

      // Pause
      playbackState.add(PlaybackState(playing: false, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-2'], false);

      // Resume
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);
      expect(carPlayItemStates['station-2'], true);
    });
  });

  group('Phone → Android Auto list play indicator sync', () {
    // Tests the ▶ prefix logic that should use actual play state,
    // not just slug match.

    test('active station shows ▶ regardless of play state', () {
      const currentSlug = 'station-1';

      final station = StationFactory.createStation(
        id: 1, slug: 'station-1', title: 'Test Radio',
      );

      // Active station always shows ▶ (like Spotify's list highlight)
      final isActive = station.slug == currentSlug;
      final title = isActive ? "▶ ${station.title}" : station.title;
      expect(title, '▶ Test Radio');
    });

    test('non-active station never shows ▶', () {
      const currentSlug = 'station-2';

      final station = StationFactory.createStation(
        id: 1, slug: 'station-1', title: 'Test Radio',
      );

      final isActive = station.slug == currentSlug;
      final title = isActive ? "▶ ${station.title}" : station.title;
      expect(title, 'Test Radio');
    });

    test('Android Auto list rebuild on station change updates indicator', () async {
      final stations = StationFactory.createPlaylist(count: 3);
      final currentStation = BehaviorSubject<Station?>.seeded(stations[0]);

      // Verify list titles: station-1 is active
      var currentSlug = currentStation.value?.slug;
      var titles = stations.map((s) {
        final isActive = s.slug == currentSlug;
        return isActive ? "▶ ${s.title}" : s.title;
      }).toList();

      expect(titles[0], '▶ Station 1');
      expect(titles[1], 'Station 2');
      expect(titles[2], 'Station 3');

      // Switch to station-2
      currentStation.add(stations[1]);
      await Future.delayed(Duration.zero);

      currentSlug = currentStation.value?.slug;
      titles = stations.map((s) {
        final isActive = s.slug == currentSlug;
        return isActive ? "▶ ${s.title}" : s.title;
      }).toList();

      expect(titles[0], 'Station 1');
      expect(titles[1], '▶ Station 2');
      expect(titles[2], 'Station 3');

      currentStation.close();
    });
  });

  group('Bidirectional sync completeness', () {
    late BehaviorSubject<Station?> currentStation;
    late BehaviorSubject<PlaybackState> playbackState;
    late Map<String, bool> carPlayStates;
    late Map<String, String> androidAutoTitles;
    late List<Station> stations;
    late List<StreamSubscription> subscriptions;

    void syncCarPlay(String currentSlug) {
      final isPlaying = playbackState.value.playing;
      for (final slug in carPlayStates.keys) {
        carPlayStates[slug] = slug == currentSlug && isPlaying;
      }
    }

    void syncAndroidAuto() {
      final currentSlug = currentStation.value?.slug;
      for (final station in stations) {
        final isActive = station.slug == currentSlug;
        androidAutoTitles[station.slug] = isActive ? "▶ ${station.title}" : station.title;
      }
    }

    setUp(() {
      stations = StationFactory.createPlaylist(count: 3);
      carPlayStates = {for (final s in stations) s.slug: false};
      androidAutoTitles = {for (final s in stations) s.slug: s.title};
      currentStation = BehaviorSubject<Station?>.seeded(null);
      playbackState = BehaviorSubject<PlaybackState>.seeded(
        PlaybackState(playing: false, processingState: AudioProcessingState.idle),
      );
      subscriptions = [];

      // CarPlay subscriptions (play state dependent)
      subscriptions.add(currentStation.stream.listen((station) {
        if (station != null) syncCarPlay(station.slug);
      }));
      subscriptions.add(playbackState.stream.listen((_) {
        final slug = currentStation.value?.slug;
        if (slug != null) syncCarPlay(slug);
      }));

      // Android Auto subscription (station dependent only, not play state)
      subscriptions.add(currentStation.stream.listen((_) {
        syncAndroidAuto();
      }));
    });

    tearDown(() {
      for (final sub in subscriptions) {
        sub.cancel();
      }
      currentStation.close();
      playbackState.close();
    });

    test('phone play syncs both CarPlay and Android Auto simultaneously', () async {
      currentStation.add(stations[1]); // station-2
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);

      // CarPlay: isPlaying indicator on station-2
      expect(carPlayStates['station-1'], false);
      expect(carPlayStates['station-2'], true);
      expect(carPlayStates['station-3'], false);

      // Android Auto: ▶ prefix on station-2
      expect(androidAutoTitles['station-1'], 'Station 1');
      expect(androidAutoTitles['station-2'], '▶ Station 2');
      expect(androidAutoTitles['station-3'], 'Station 3');
    });

    test('phone pause syncs CarPlay but AA keeps active indicator', () async {
      currentStation.add(stations[0]);
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);

      expect(carPlayStates['station-1'], true);
      expect(androidAutoTitles['station-1'], '▶ Station 1');

      // Pause: CarPlay clears playing indicator, AA keeps active indicator
      playbackState.add(PlaybackState(playing: false, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);

      expect(carPlayStates['station-1'], false);
      // AA ▶ persists because it indicates the active station, not play state
      expect(androidAutoTitles['station-1'], '▶ Station 1');
    });

    test('phone station change syncs both platforms', () async {
      currentStation.add(stations[0]);
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);

      // Switch station from phone
      currentStation.add(stations[2]);
      await Future.delayed(Duration.zero);

      // CarPlay: moved indicator
      expect(carPlayStates['station-1'], false);
      expect(carPlayStates['station-3'], true);

      // Android Auto: moved ▶
      expect(androidAutoTitles['station-1'], 'Station 1');
      expect(androidAutoTitles['station-3'], '▶ Station 3');
    });

    test('rapid play/pause/switch produces correct final state on both', () async {
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      currentStation.add(stations[0]);
      currentStation.add(stations[1]);
      playbackState.add(PlaybackState(playing: false, processingState: AudioProcessingState.ready));
      currentStation.add(stations[2]);
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      await Future.delayed(Duration.zero);

      // Final state: station-3 playing
      expect(carPlayStates['station-1'], false);
      expect(carPlayStates['station-2'], false);
      expect(carPlayStates['station-3'], true);

      expect(androidAutoTitles['station-1'], 'Station 1');
      expect(androidAutoTitles['station-2'], 'Station 2');
      expect(androidAutoTitles['station-3'], '▶ Station 3');
    });
  });
}
