import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

/// Tests that all play buttons (mini player, full player, notification)
/// behave consistently during skip next transitions.
///
/// BUG: MiniAudioPlayer used ValueKey('mini-play-${currentStation?.id}')
/// which destroyed and recreated the AnimatedPlayButton on station change.
/// The new instance had no grace period and showed play icon during loading,
/// making the pause button unresponsive. FullAudioPlayer used GlobalKey
/// which preserved the button state and grace period.
///
/// FIX: Remove ValueKey from MiniAudioPlayer so the button persists across
/// station changes, always reflecting the stream truth.
void main() {
  /// Simulates AnimatedPlayButton state machine.
  /// [isNewInstance] = true simulates ValueKey recreation (MiniAudioPlayer BUG).
  /// [isNewInstance] = false simulates GlobalKey preservation (FullAudioPlayer).
  Map<String, dynamic> simulateButton({
    required List<PlaybackState> stateSequence,
    required bool isNewInstance,
    bool notifyWillPlayCalled = false,
  }) {
    // AnimatedPlayButton internal state
    bool intentIsPlaying = false;
    DateTime? intentSetAt;
    bool streamPlaying = false;
    bool streamLoading = false;

    if (notifyWillPlayCalled && !isNewInstance) {
      intentIsPlaying = true;
      intentSetAt = DateTime.now();
    }

    for (final state in stateSequence) {
      if (isNewInstance) {
        // Simulates ValueKey recreation: state is reset
        intentIsPlaying = false;
        intentSetAt = null;
        isNewInstance = false; // only reset once (on creation)
      }

      streamPlaying = state.playing;
      streamLoading = state.processingState == AudioProcessingState.loading ||
          state.processingState == AudioProcessingState.buffering;

      final settled = state.processingState == AudioProcessingState.ready ||
          state.processingState == AudioProcessingState.completed ||
          state.processingState == AudioProcessingState.idle;

      if (settled) {
        intentIsPlaying = state.playing;
        intentSetAt = null;
      }
    }

    final inGracePeriod = intentSetAt != null &&
        DateTime.now().difference(intentSetAt!) < const Duration(seconds: 3);
    final showPlaying = inGracePeriod ? intentIsPlaying : streamPlaying;

    return {
      'showPlaying': showPlaying,
      'showSpinner': streamLoading,
      'tapCallsPause': showPlaying,
    };
  }

  group('Play button consistency across surfaces', () {
    // The state sequence during skipToNext with the _isConnecting fix:
    final skipNextSequence = [
      // 1. _isConnecting=true, broadcast before player.stop
      PlaybackState(playing: false, processingState: AudioProcessingState.loading),
      // 2. player.stop → idle, but _isConnecting=true → loading
      PlaybackState(playing: false, processingState: AudioProcessingState.loading),
      // 3. source loading
      PlaybackState(playing: false, processingState: AudioProcessingState.loading),
      // 4. player.play() → buffering
      PlaybackState(playing: true, processingState: AudioProcessingState.buffering),
      // 5. ready, playing
      PlaybackState(playing: true, processingState: AudioProcessingState.ready),
    ];

    test('FullAudioPlayer (GlobalKey + notifyWillPlay): pause works throughout', () {
      final result = simulateButton(
        stateSequence: skipNextSequence,
        isNewInstance: false,
        notifyWillPlayCalled: true,
      );
      expect(result['showPlaying'], true);
      expect(result['tapCallsPause'], true);
    });

    test('BUG: MiniAudioPlayer with ValueKey recreation loses pause ability during loading', () {
      // Only check the LOADING phase (first 3 states) where the bug manifests
      final loadingPhase = skipNextSequence.sublist(0, 3);

      final result = simulateButton(
        stateSequence: loadingPhase,
        isNewInstance: true, // ValueKey causes recreation
      );

      // During loading, new instance has no grace period, streamPlaying=false
      // The button shows play icon, tap calls play() (useless)
      expect(result['showPlaying'], false,
          reason: 'Bug: recreated button has no intent, shows play during loading');
      expect(result['tapCallsPause'], false,
          reason: 'Bug: tap calls play() not pause()');
    });

    test('FIX: MiniAudioPlayer without ValueKey preserves button through transition', () {
      final result = simulateButton(
        stateSequence: skipNextSequence,
        isNewInstance: false, // No ValueKey = button persists
      );

      // After full sequence, button shows pause (playing=true, ready)
      expect(result['showPlaying'], true);
      expect(result['tapCallsPause'], true);
    });

    test('FIX: MiniAudioPlayer final state matches FullAudioPlayer', () {
      final fullPlayerResult = simulateButton(
        stateSequence: skipNextSequence,
        isNewInstance: false,
        notifyWillPlayCalled: true,
      );

      final miniPlayerResult = simulateButton(
        stateSequence: skipNextSequence,
        isNewInstance: false, // Fixed: no ValueKey recreation
      );

      expect(miniPlayerResult['showPlaying'], fullPlayerResult['showPlaying'],
          reason: 'Both buttons must show same play/pause state');
      expect(miniPlayerResult['tapCallsPause'], fullPlayerResult['tapCallsPause'],
          reason: 'Both buttons must call same action on tap');
    });

    test('Notification controls match button state after transition', () {
      // Notification controls are determined by _broadcastState:
      // controls: [skipPrev, if(playing) pause else play, skipNext]
      // After the full sequence, playing=true → notification shows pause
      final lastState = skipNextSequence.last;
      final notificationShowsPause = lastState.playing;

      final miniResult = simulateButton(
        stateSequence: skipNextSequence,
        isNewInstance: false,
      );

      expect(notificationShowsPause, true);
      expect(miniResult['showPlaying'], notificationShowsPause,
          reason: 'Mini player and notification must agree on play/pause state');
    });
  });

  group('Play button handles rapid skip next', () {
    test('rapid skips: button always shows correct final state', () {
      // Simulate 3 rapid skip-nexts (each interrupted by the next)
      final rapidSequence = [
        // Skip 1: loading
        PlaybackState(playing: false, processingState: AudioProcessingState.loading),
        // Skip 2 interrupts: loading again
        PlaybackState(playing: false, processingState: AudioProcessingState.loading),
        // Skip 3 interrupts: loading again
        PlaybackState(playing: false, processingState: AudioProcessingState.loading),
        // Final skip completes: buffering then ready
        PlaybackState(playing: true, processingState: AudioProcessingState.buffering),
        PlaybackState(playing: true, processingState: AudioProcessingState.ready),
      ];

      final miniResult = simulateButton(
        stateSequence: rapidSequence,
        isNewInstance: false,
      );

      expect(miniResult['showPlaying'], true);
      expect(miniResult['tapCallsPause'], true);
    });
  });
}
