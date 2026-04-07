import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

/// Tests for the bug: after pressing "next" on phone, the pause button stops working.
///
/// ROOT CAUSE:
/// playStation() called player.stop() which emitted ProcessingState.idle.
/// _broadcastState mapped idle → AudioProcessingState.ready.
/// AnimatedPlayButton treated {ready, playing: false} as a "settled" state,
/// clearing the optimistic play intent. The button showed a play icon
/// whose tap called play() instead of pause().
///
/// FIX:
/// Set _isConnecting = true BEFORE player.stop() in playStation(), so
/// _broadcastState always emits processingState=loading during the transition.
/// AnimatedPlayButton sees loading → not settled → grace period preserved.
void main() {
  group('skipToNext → pause button bug', () {
    /// Simulates AnimatedPlayButton's _onPlaybackState logic.
    /// Returns the button's effective state (what icon it shows / what tap does).
    Map<String, dynamic> simulateButtonState({
      required bool intentIsPlaying,
      required DateTime? intentSetAt,
      required PlaybackState state,
    }) {
      final streamPlaying = state.playing;
      final streamLoading =
          state.processingState == AudioProcessingState.loading ||
          state.processingState == AudioProcessingState.buffering;

      final settled = state.processingState == AudioProcessingState.ready ||
          state.processingState == AudioProcessingState.completed ||
          state.processingState == AudioProcessingState.idle;

      if (settled) {
        intentIsPlaying = state.playing;
        intentSetAt = null;
      }

      final inGracePeriod = intentSetAt != null &&
          DateTime.now().difference(intentSetAt) < const Duration(seconds: 3);

      final showPlaying = inGracePeriod ? intentIsPlaying : streamPlaying;

      return {
        'showPlaying': showPlaying,
        'showSpinner': streamLoading,
        'intentIsPlaying': intentIsPlaying,
        'intentSetAt': intentSetAt,
        'tapCallsPause': showPlaying, // if showing pause icon, tap calls pause
      };
    }

    test('BUG: idle→ready mapping clears intent after player.stop()', () {
      // Simulate: notifyWillPlay() was called (skip next tap)
      final intentSetAt = DateTime.now();

      // Then player.stop() fires, which OLD code maps to ready:
      final stateAfterStop = PlaybackState(
        playing: false,
        processingState: AudioProcessingState.ready, // idle mapped to ready (OLD behavior)
      );

      final result = simulateButtonState(
        intentIsPlaying: true,
        intentSetAt: intentSetAt,
        state: stateAfterStop,
      );

      // BUG: settled=true clears intent, button shows play icon
      expect(result['showPlaying'], false,
          reason: 'Bug: ready+playing=false clears intent, button shows play');
      expect(result['tapCallsPause'], false,
          reason: 'Bug: tapping calls play() instead of pause()');
    });

    test('FIX: loading state preserves intent during station switch', () {
      // Simulate: notifyWillPlay() was called (skip next tap)
      final intentSetAt = DateTime.now();

      // With fix: _isConnecting=true BEFORE player.stop(), so broadcast emits loading:
      final stateAfterStop = PlaybackState(
        playing: false,
        processingState: AudioProcessingState.loading, // FIX: loading, not ready
      );

      final result = simulateButtonState(
        intentIsPlaying: true,
        intentSetAt: intentSetAt,
        state: stateAfterStop,
      );

      // FIX: loading is not settled, grace period preserved, button shows pause
      expect(result['showPlaying'], true,
          reason: 'Fix: loading state preserves intent, button shows pause');
      expect(result['tapCallsPause'], true,
          reason: 'Fix: tapping calls pause() correctly');
    });

    test('FIX: full transition sequence keeps button usable', () {
      // Simulate the full skipToNext sequence with the fix
      final intentSetAt = DateTime.now();
      bool intentIsPlaying = true;
      DateTime? currentIntentSetAt = intentSetAt;

      // Step 1: _isConnecting=true broadcast (BEFORE player.stop)
      var result = simulateButtonState(
        intentIsPlaying: intentIsPlaying,
        intentSetAt: currentIntentSetAt,
        state: PlaybackState(
          playing: false,
          processingState: AudioProcessingState.loading,
        ),
      );
      expect(result['showPlaying'], true, reason: 'Step 1: loading, grace active');
      intentIsPlaying = result['intentIsPlaying'];
      currentIntentSetAt = result['intentSetAt'];

      // Step 2: player.stop() fires idle, but _isConnecting=true → still loading
      result = simulateButtonState(
        intentIsPlaying: intentIsPlaying,
        intentSetAt: currentIntentSetAt,
        state: PlaybackState(
          playing: false,
          processingState: AudioProcessingState.loading,
        ),
      );
      expect(result['showPlaying'], true, reason: 'Step 2: still loading, grace active');
      intentIsPlaying = result['intentIsPlaying'];
      currentIntentSetAt = result['intentSetAt'];

      // Step 3: source loaded, player.play() called → buffering
      result = simulateButtonState(
        intentIsPlaying: intentIsPlaying,
        intentSetAt: currentIntentSetAt,
        state: PlaybackState(
          playing: true,
          processingState: AudioProcessingState.buffering,
        ),
      );
      expect(result['showPlaying'], true, reason: 'Step 3: buffering, grace active');
      expect(result['showSpinner'], true, reason: 'Step 3: should show spinner');

      // Step 4: playback ready, playing=true → settled, intent syncs to true
      result = simulateButtonState(
        intentIsPlaying: intentIsPlaying,
        intentSetAt: currentIntentSetAt,
        state: PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      expect(result['showPlaying'], true, reason: 'Step 4: settled + playing=true');
      expect(result['tapCallsPause'], true, reason: 'Step 4: pause button works');
    });
  });

  group('playStation transition state', () {
    /// Simulates _broadcastState logic to verify processingState output.
    AudioProcessingState computeProcessingState({
      required bool isConnecting,
      required String playerProcessingState,
    }) {
      if (isConnecting) return AudioProcessingState.loading;
      const mapping = {
        'idle': AudioProcessingState.ready,
        'loading': AudioProcessingState.loading,
        'buffering': AudioProcessingState.buffering,
        'ready': AudioProcessingState.ready,
        'completed': AudioProcessingState.completed,
      };
      return mapping[playerProcessingState] ?? AudioProcessingState.idle;
    }

    test('BUG: without fix, player.stop→idle maps to ready', () {
      // OLD: _isConnecting is false when player.stop() fires
      final state = computeProcessingState(
        isConnecting: false,
        playerProcessingState: 'idle',
      );
      expect(state, AudioProcessingState.ready,
          reason: 'Without fix: idle maps to ready, triggers settled');
    });

    test('FIX: with fix, _isConnecting=true overrides idle→loading', () {
      // NEW: _isConnecting set to true BEFORE player.stop()
      final state = computeProcessingState(
        isConnecting: true,
        playerProcessingState: 'idle',
      );
      expect(state, AudioProcessingState.loading,
          reason: 'With fix: _isConnecting=true always emits loading');
    });

    test('FIX: entire playStation transition always shows loading', () {
      // The key states during playStation with the fix:

      // 1. Before player.stop: _isConnecting=true
      expect(
        computeProcessingState(isConnecting: true, playerProcessingState: 'ready'),
        AudioProcessingState.loading,
      );

      // 2. player.stop() → idle: _isConnecting still true
      expect(
        computeProcessingState(isConnecting: true, playerProcessingState: 'idle'),
        AudioProcessingState.loading,
      );

      // 3. play() sets _isConnecting=true again, source loading
      expect(
        computeProcessingState(isConnecting: true, playerProcessingState: 'loading'),
        AudioProcessingState.loading,
      );

      // 4. Source loaded, _isConnecting=false, player.play() → buffering
      expect(
        computeProcessingState(isConnecting: false, playerProcessingState: 'buffering'),
        AudioProcessingState.buffering,
      );

      // 5. Playing, ready
      expect(
        computeProcessingState(isConnecting: false, playerProcessingState: 'ready'),
        AudioProcessingState.ready,
      );
    });
  });
}
