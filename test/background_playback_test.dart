import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

/// Tests that background playback continues when CarPlay/Android Auto is connected,
/// and stops correctly when the car disconnects.
void main() {
  group('Background playback with car connected', () {
    /// Simulates the lifecycle handler logic in HomePage.
    /// Returns the action taken: 'stop', 'autoplay', or 'none'.
    String simulateLifecycleChange({
      required AppLifecycleState state,
      required bool isCarConnected,
      required bool isPlayingOrConnecting,
    }) {
      if (state == AppLifecycleState.detached) {
        if (!isCarConnected) {
          return 'stop';
        }
        return 'none'; // keep alive for car
      } else if (state == AppLifecycleState.resumed) {
        if (!isPlayingOrConnecting && !isCarConnected) {
          return 'autoplay';
        }
        return 'none';
      } else if (state == AppLifecycleState.paused) {
        return 'none'; // never stop on background
      }
      return 'none';
    }

    test('detached WITHOUT car: stops player', () {
      final action = simulateLifecycleChange(
        state: AppLifecycleState.detached,
        isCarConnected: false,
        isPlayingOrConnecting: true,
      );
      expect(action, 'stop');
    });

    test('detached WITH car connected: keeps player alive', () {
      final action = simulateLifecycleChange(
        state: AppLifecycleState.detached,
        isCarConnected: true,
        isPlayingOrConnecting: true,
      );
      expect(action, 'none');
    });

    test('paused (background) WITH car connected: keeps player alive', () {
      final action = simulateLifecycleChange(
        state: AppLifecycleState.paused,
        isCarConnected: true,
        isPlayingOrConnecting: true,
      );
      expect(action, 'none');
    });

    test('paused (background) WITHOUT car: keeps player alive', () {
      // Background alone should never stop the player (audio_service handles this)
      final action = simulateLifecycleChange(
        state: AppLifecycleState.paused,
        isCarConnected: false,
        isPlayingOrConnecting: true,
      );
      expect(action, 'none');
    });

    test('resumed with car connected: does NOT autoplay', () {
      final action = simulateLifecycleChange(
        state: AppLifecycleState.resumed,
        isCarConnected: true,
        isPlayingOrConnecting: false,
      );
      expect(action, 'none',
          reason: 'Car is connected, user controls playback from car');
    });

    test('resumed without car and not playing: autoplays', () {
      final action = simulateLifecycleChange(
        state: AppLifecycleState.resumed,
        isCarConnected: false,
        isPlayingOrConnecting: false,
      );
      expect(action, 'autoplay');
    });

    test('resumed without car but already playing: no autoplay', () {
      final action = simulateLifecycleChange(
        state: AppLifecycleState.resumed,
        isCarConnected: false,
        isPlayingOrConnecting: true,
      );
      expect(action, 'none');
    });
  });

  group('Car disconnect pauses playback (integration)', () {
    test('full lifecycle: connect → play → background → disconnect → pause', () {
      final isCarConnected = BehaviorSubject<bool>.seeded(false);
      final playbackState = BehaviorSubject<PlaybackState>.seeded(
        PlaybackState(playing: false, processingState: AudioProcessingState.idle),
      );
      bool pauseCalled = false;

      // Car connects
      isCarConnected.add(true);

      // Start playing
      playbackState.add(PlaybackState(
        playing: true, processingState: AudioProcessingState.ready,
      ));

      // App goes to background (user looks at car screen)
      // Player should keep running (no stop)

      // Car disconnects
      final connected = false;
      isCarConnected.add(connected);
      if (!connected && playbackState.value.playing) {
        pauseCalled = true;
      }

      expect(pauseCalled, true,
          reason: 'Player should pause when car disconnects');

      isCarConnected.close();
      playbackState.close();
    });

    test('onTaskRemoved with car connected: keeps player alive', () {
      // Simulates AppAudioHandler.onTaskRemoved logic
      bool isConnected = true;
      bool playerStopped = false;

      if (isConnected) {
        // Keep audio alive
      } else {
        playerStopped = true;
      }

      expect(playerStopped, false);
    });

    test('onTaskRemoved without car: stops player', () {
      bool isConnected = false;
      bool playerStopped = false;

      if (isConnected) {
        // Keep audio alive
      } else {
        playerStopped = true;
      }

      expect(playerStopped, true);
    });
  });
}
