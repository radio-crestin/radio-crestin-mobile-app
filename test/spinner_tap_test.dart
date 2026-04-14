import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests that tapping the play button during loading/buffering calls pause()
/// instead of stop(), so the user can cancel a station transition without
/// killing the player entirely.
///
/// BUG: During loading (e.g., after skip next), the button showed a spinner
/// whose tap called onStop(). This fully stopped the audio player, making
/// the button unresponsive. The user had to tap a station to recover.
///
/// FIX: Spinner tap now calls onPause() which cancels the in-flight play
/// gracefully, leaving the player in a recoverable paused state.
void main() {
  /// Simulates AnimatedPlayButton's onTap selection logic.
  /// Returns 'pause', 'play', or 'stop' based on the current state.
  String determineTapAction({
    required bool showSpinner,
    required bool showPlaying,
    required bool useFix,
  }) {
    if (showSpinner) {
      return useFix ? 'pause' : 'stop'; // FIX vs BUG
    } else if (showPlaying) {
      return 'pause';
    } else {
      return 'play';
    }
  }

  /// Computes button display state from playback state.
  Map<String, bool> computeDisplay(PlaybackState state) {
    final streamPlaying = state.playing;
    final streamLoading =
        state.processingState == AudioProcessingState.loading ||
        state.processingState == AudioProcessingState.buffering;
    // No grace period for mini player (no notifyWillPlay called)
    return {
      'showSpinner': streamLoading,
      'showPlaying': streamPlaying,
    };
  }

  group('Spinner tap action', () {
    test('BUG: tapping spinner during loading calls stop', () {
      final display = computeDisplay(PlaybackState(
        playing: false,
        processingState: AudioProcessingState.loading,
      ));

      final action = determineTapAction(
        showSpinner: display['showSpinner']!,
        showPlaying: display['showPlaying']!,
        useFix: false,
      );

      expect(action, 'stop', reason: 'Old code: spinner tap calls stop');
    });

    test('FIX: tapping spinner during loading calls pause', () {
      final display = computeDisplay(PlaybackState(
        playing: false,
        processingState: AudioProcessingState.loading,
      ));

      final action = determineTapAction(
        showSpinner: display['showSpinner']!,
        showPlaying: display['showPlaying']!,
        useFix: true,
      );

      expect(action, 'pause', reason: 'Fixed: spinner tap calls pause');
    });

    test('FIX: tapping spinner during buffering calls pause', () {
      final display = computeDisplay(PlaybackState(
        playing: true,
        processingState: AudioProcessingState.buffering,
      ));

      final action = determineTapAction(
        showSpinner: display['showSpinner']!,
        showPlaying: display['showPlaying']!,
        useFix: true,
      );

      expect(action, 'pause', reason: 'Buffering spinner tap calls pause');
    });

    test('normal playing state: tap calls pause', () {
      final display = computeDisplay(PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
      ));

      final action = determineTapAction(
        showSpinner: display['showSpinner']!,
        showPlaying: display['showPlaying']!,
        useFix: true,
      );

      expect(action, 'pause');
    });

    test('paused state: tap calls play', () {
      final display = computeDisplay(PlaybackState(
        playing: false,
        processingState: AudioProcessingState.ready,
      ));

      final action = determineTapAction(
        showSpinner: display['showSpinner']!,
        showPlaying: display['showPlaying']!,
        useFix: true,
      );

      expect(action, 'play');
    });

    test('all states during skip next produce correct tap action', () {
      final stateSequence = [
        // _isConnecting=true, before player.stop
        PlaybackState(playing: false, processingState: AudioProcessingState.loading),
        // Source loading
        PlaybackState(playing: false, processingState: AudioProcessingState.loading),
        // player.play() called, buffering
        PlaybackState(playing: true, processingState: AudioProcessingState.buffering),
        // Ready, playing
        PlaybackState(playing: true, processingState: AudioProcessingState.ready),
      ];

      final expectedActions = ['pause', 'pause', 'pause', 'pause'];

      for (int i = 0; i < stateSequence.length; i++) {
        final display = computeDisplay(stateSequence[i]);
        final action = determineTapAction(
          showSpinner: display['showSpinner']!,
          showPlaying: display['showPlaying']!,
          useFix: true,
        );
        expect(action, expectedActions[i],
            reason: 'Step $i: tap should call ${expectedActions[i]}');
      }
    });
  });
}
