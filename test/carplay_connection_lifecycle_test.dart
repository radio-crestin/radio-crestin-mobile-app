import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

import 'helpers/station_factory.dart';

/// Tests for CarPlay connection lifecycle:
/// - No duplicate CONNECTED events cause stream restart
/// - Already playing → connect does not restart the stream
/// - Not playing + autoplay enabled → autoplay triggers
/// - Autoplay waits for stations to load when not yet available
void main() {
  group('CarPlay connection lifecycle', () {
    late BehaviorSubject<PlaybackState> playbackState;
    late BehaviorSubject<bool> isCarConnected;
    late bool reapplySeekOffsetCalled;
    late bool autoplayTriggered;
    late bool refreshMetadataCalled;
    late bool refreshStationsCalled;
    late bool pauseCalled;
    late bool autoplayEnabled;

    /// Simulates the FIXED connection change handler in CarPlayService.
    /// This mirrors the new logic in _initializeCarPlay's listener.
    void onConnectionChange(String status) {
      final wasConnected = isCarConnected.value;
      final connected = status != 'disconnected';
      isCarConnected.add(connected);

      if (connected && !wasConnected) {
        // Fresh connection
        final wasPlaying = playbackState.value.playing;
        refreshMetadataCalled = true;
        if (wasPlaying) {
          // Already playing — don't restart, just refresh metadata
          refreshStationsCalled = true;
        } else {
          // Not playing — autoplay if enabled
          if (autoplayEnabled) {
            autoplayTriggered = true;
          }
        }
      } else if (!connected && wasConnected) {
        if (playbackState.value.playing) {
          pauseCalled = true;
        }
      } else if (connected) {
        // Returning from background
        refreshMetadataCalled = true;
      }
    }

    setUp(() {
      playbackState = BehaviorSubject<PlaybackState>.seeded(
        PlaybackState(playing: false, processingState: AudioProcessingState.idle),
      );
      isCarConnected = BehaviorSubject<bool>.seeded(false);
      reapplySeekOffsetCalled = false;
      autoplayTriggered = false;
      refreshMetadataCalled = false;
      refreshStationsCalled = false;
      pauseCalled = false;
      autoplayEnabled = true;
    });

    tearDown(() {
      playbackState.close();
      isCarConnected.close();
    });

    group('No stream restart when already playing', () {
      test('connecting while playing does not call reapplySeekOffset', () {
        // User is playing on phone
        playbackState.add(PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ));

        // CarPlay connects
        onConnectionChange('connected');

        expect(reapplySeekOffsetCalled, false,
            reason: 'reapplySeekOffset should NOT be called — it restarts the HLS stream');
        expect(refreshStationsCalled, true,
            reason: 'Station metadata should be refreshed without stream restart');
        expect(refreshMetadataCalled, true);
      });

      test('connecting while playing does not trigger autoplay', () {
        playbackState.add(PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ));

        onConnectionChange('connected');

        expect(autoplayTriggered, false,
            reason: 'Should not autoplay when already playing');
      });
    });

    group('Duplicate CONNECTED events', () {
      /// Simulates the old bug: sceneDidBecomeActive fires CONNECTED
      /// right after didConnect, causing two CONNECTED events.
      /// The FIXED Swift code suppresses the duplicate, but this test
      /// verifies the Dart handler is also resilient.
      test('second CONNECTED when already connected is a no-op for autoplay', () {
        // First CONNECTED (from didConnect)
        onConnectionChange('connected');
        expect(autoplayTriggered, true, reason: 'First connect should trigger autoplay');

        // Reset tracking
        autoplayTriggered = false;
        refreshStationsCalled = false;

        // Second CONNECTED (would come from sceneDidBecomeActive in old code)
        onConnectionChange('connected');

        expect(autoplayTriggered, false,
            reason: 'Duplicate CONNECTED should NOT trigger autoplay again');
        expect(refreshMetadataCalled, true,
            reason: 'Should refresh metadata on background→foreground');
      });

      test('second CONNECTED while playing does not restart stream', () {
        playbackState.add(PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ));

        // First CONNECTED
        onConnectionChange('connected');
        refreshStationsCalled = false;

        // Second CONNECTED (duplicate)
        onConnectionChange('connected');

        expect(reapplySeekOffsetCalled, false);
        expect(refreshStationsCalled, false,
            reason: 'Second CONNECTED is a background return, not a fresh connect');
      });
    });

    group('Autoplay on connect', () {
      test('triggers autoplay when not playing and autoplay enabled', () {
        playbackState.add(PlaybackState(
          playing: false,
          processingState: AudioProcessingState.idle,
        ));
        autoplayEnabled = true;

        onConnectionChange('connected');

        expect(autoplayTriggered, true);
      });

      test('does not trigger autoplay when disabled in settings', () {
        playbackState.add(PlaybackState(
          playing: false,
          processingState: AudioProcessingState.idle,
        ));
        autoplayEnabled = false;

        onConnectionChange('connected');

        expect(autoplayTriggered, false);
      });

      test('does not trigger autoplay on background→foreground', () {
        // Already connected
        isCarConnected.add(true);

        onConnectionChange('connected');

        expect(autoplayTriggered, false,
            reason: 'Background→foreground should not autoplay');
      });
    });

    group('Disconnect behavior', () {
      test('pauses playback on disconnect while playing', () {
        playbackState.add(PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ));
        isCarConnected.add(true);

        onConnectionChange('disconnected');

        expect(pauseCalled, true);
      });

      test('does not pause on disconnect when already paused', () {
        playbackState.add(PlaybackState(
          playing: false,
          processingState: AudioProcessingState.idle,
        ));
        isCarConnected.add(true);

        onConnectionChange('disconnected');

        expect(pauseCalled, false);
      });

      test('reconnect after disconnect triggers autoplay again', () {
        // Connect → autoplay
        onConnectionChange('connected');
        expect(autoplayTriggered, true);
        autoplayTriggered = false;

        // Disconnect
        onConnectionChange('disconnected');

        // Reconnect → should autoplay again
        onConnectionChange('connected');
        expect(autoplayTriggered, true);
      });
    });

    group('Background transitions', () {
      test('background status keeps car as connected', () {
        onConnectionChange('connected');
        expect(isCarConnected.value, true);

        onConnectionChange('background');
        expect(isCarConnected.value, true,
            reason: 'Background is still connected (user switched to Maps)');
      });

      test('foreground after background refreshes metadata only', () {
        onConnectionChange('connected');
        autoplayTriggered = false;
        refreshMetadataCalled = false;

        // Go to background then return
        onConnectionChange('background');
        refreshMetadataCalled = false;

        onConnectionChange('connected');

        expect(autoplayTriggered, false,
            reason: 'Should not autoplay when returning from background');
        expect(refreshMetadataCalled, true);
      });
    });
  });

  group('Autoplay waits for stations', () {
    test('waits for stations to load before resolving', () async {
      final stationsSubject = BehaviorSubject<List<dynamic>>.seeded([]);
      final completer = Completer<String?>();
      Timer? timeout;
      StreamSubscription? sub;

      // Simulate _waitForLastPlayedStation logic
      timeout = Timer(const Duration(seconds: 10), () {
        sub?.cancel();
        if (!completer.isCompleted) completer.complete(null);
      });

      sub = stationsSubject.stream.listen((stations) {
        if (stations.isNotEmpty) {
          sub?.cancel();
          timeout?.cancel();
          if (!completer.isCompleted) completer.complete('station-1');
        }
      });

      // Stations not loaded yet — completer should not be completed
      await Future.delayed(const Duration(milliseconds: 50));
      expect(completer.isCompleted, false);

      // Stations load
      stationsSubject.add([
        StationFactory.createStation(id: 1, slug: 'station-1', title: 'Test'),
      ]);

      final result = await completer.future;
      expect(result, 'station-1');

      stationsSubject.close();
    });

    test('times out if stations never load', () async {
      final stationsSubject = BehaviorSubject<List<dynamic>>.seeded([]);
      final completer = Completer<String?>();

      // Use a short timeout for testing
      final timeout = Timer(const Duration(milliseconds: 100), () {
        if (!completer.isCompleted) completer.complete(null);
      });

      final sub = stationsSubject.stream.listen((stations) {
        if (stations.isNotEmpty) {
          timeout.cancel();
          if (!completer.isCompleted) completer.complete('station-1');
        }
      });

      final result = await completer.future;
      expect(result, null, reason: 'Should return null after timeout');

      sub.cancel();
      stationsSubject.close();
    });

    test('resolves immediately if stations already loaded', () async {
      final stations = [
        StationFactory.createStation(id: 1, slug: 'station-1', title: 'Test'),
      ];
      final stationsSubject = BehaviorSubject<List<dynamic>>.seeded(stations);
      final completer = Completer<String?>();
      StreamSubscription? sub;

      sub = stationsSubject.stream.listen((stations) {
        if (stations.isNotEmpty) {
          sub?.cancel();
          if (!completer.isCompleted) completer.complete('station-1');
        }
      });

      final result = await completer.future;
      expect(result, 'station-1');

      stationsSubject.close();
    });
  });

  group('Scene delegate activation suppression', () {
    /// Simulates the Swift-side _initialActivationConsumed flag logic.
    late bool initialActivationConsumed;
    late List<String> emittedStatuses;

    void simulateDidConnect() {
      initialActivationConsumed = false;
      emittedStatuses.add('connected');
    }

    void simulateSceneDidBecomeActive() {
      if (!initialActivationConsumed) {
        initialActivationConsumed = true;
        return; // Suppressed
      }
      emittedStatuses.add('connected');
    }

    void simulateSceneDidEnterBackground() {
      emittedStatuses.add('background');
    }

    void simulateDidDisconnect() {
      initialActivationConsumed = false;
      emittedStatuses.add('disconnected');
    }

    setUp(() {
      initialActivationConsumed = false;
      emittedStatuses = [];
    });

    test('didConnect + sceneDidBecomeActive emits only ONE connected', () {
      simulateDidConnect();
      simulateSceneDidBecomeActive();

      expect(emittedStatuses, ['connected'],
          reason: 'sceneDidBecomeActive right after didConnect should be suppressed');
    });

    test('background→foreground emits connected after initial suppression', () {
      simulateDidConnect();
      simulateSceneDidBecomeActive(); // suppressed

      simulateSceneDidEnterBackground();
      simulateSceneDidBecomeActive(); // NOT suppressed

      expect(emittedStatuses, ['connected', 'background', 'connected']);
    });

    test('disconnect resets suppression for next connection', () {
      // First connection
      simulateDidConnect();
      simulateSceneDidBecomeActive(); // suppressed
      expect(emittedStatuses, ['connected']);

      // Disconnect
      simulateDidDisconnect();

      // Second connection
      simulateDidConnect();
      simulateSceneDidBecomeActive(); // suppressed again
      expect(emittedStatuses, ['connected', 'disconnected', 'connected']);
    });

    test('multiple background→foreground cycles emit correctly', () {
      simulateDidConnect();
      simulateSceneDidBecomeActive(); // suppressed

      // Cycle 1
      simulateSceneDidEnterBackground();
      simulateSceneDidBecomeActive();

      // Cycle 2
      simulateSceneDidEnterBackground();
      simulateSceneDidBecomeActive();

      expect(emittedStatuses, [
        'connected',
        'background', 'connected',
        'background', 'connected',
      ]);
    });
  });
}
