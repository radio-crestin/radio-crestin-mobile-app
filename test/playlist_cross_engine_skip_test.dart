import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the cross-engine skip bug: skipping from a buffering
/// audio playlist item onto a video (media_kit) or youtube item let the OLD
/// just_audio load finish and call `play()` — audio kept playing under the new
/// item ("zombie audio"), and the new item never settled into playing state.
///
/// ROOT CAUSE:
/// `playPlaylistAudioItem` guards its awaits with `_playOperationId`, but the
/// takeover paths (`_enterVideoMode`, `stopPlaylistPlayback`) never bumped it —
/// so the in-flight audio operation was still "current" when its awaited
/// setAudioSource/seek returned, and it happily started playback.
///
/// FIX:
/// Both takeover paths call `_cancelInFlightPlay()` (bumping the op id), and
/// `playPlaylistAudioItem` re-checks the op id after EVERY await (stop, load,
/// seek, broadcast) before finally calling `play()`.
///
/// The simulator below mirrors that protocol so the interleaving is testable
/// without real players (same style as skip_next_pause_test.dart).
class _EngineSimulator {
  int opId = 0;
  bool audioPlaying = false;
  bool videoPlaying = false;

  /// Mirrors `playPlaylistAudioItem`: bumps the op id, awaits the (slow) load,
  /// and only plays when still current.
  Future<void> playAudioItem(Future<void> load) async {
    final myOp = ++opId;
    audioPlaying = false;
    await load;
    if (myOp != opId) return; // superseded while loading
    audioPlaying = true;
  }

  /// Mirrors `_enterVideoMode` after the fix: invalidates in-flight audio
  /// loads, then starts video.
  Future<void> playVideoItem() async {
    ++opId; // _cancelInFlightPlay()
    audioPlaying = false;
    videoPlaying = true;
  }

  /// Mirrors `stopPlaylistPlayback` after the fix.
  Future<void> stopAll() async {
    ++opId; // _cancelInFlightPlay()
    audioPlaying = false;
    videoPlaying = false;
  }
}

void main() {
  group('cross-engine skip supersedes in-flight audio load', () {
    test('audio → video skip mid-load: audio never starts (no zombie audio)',
        () async {
      final sim = _EngineSimulator();
      final slowLoad = Future<void>.delayed(const Duration(milliseconds: 20));

      final audioFuture = sim.playAudioItem(slowLoad);
      // User presses next before the audio item finished loading.
      await sim.playVideoItem();
      await audioFuture;

      expect(sim.videoPlaying, isTrue);
      expect(sim.audioPlaying, isFalse,
          reason: 'superseded audio load must not start playback');
    });

    test('audio → youtube skip mid-load: stopAll wins over the audio load',
        () async {
      final sim = _EngineSimulator();
      final slowLoad = Future<void>.delayed(const Duration(milliseconds: 20));

      final audioFuture = sim.playAudioItem(slowLoad);
      await sim.stopAll(); // youtube items stop local engines first
      await audioFuture;

      expect(sim.audioPlaying, isFalse);
      expect(sim.videoPlaying, isFalse);
    });

    test('un-superseded audio load still plays normally', () async {
      final sim = _EngineSimulator();
      await sim.playAudioItem(Future<void>.value());
      expect(sim.audioPlaying, isTrue);
    });

    test('rapid audio → audio skip: only the last item plays', () async {
      final sim = _EngineSimulator();
      final first =
          sim.playAudioItem(Future<void>.delayed(const Duration(milliseconds: 20)));
      final second = sim.playAudioItem(Future<void>.value());
      await Future.wait([first, second]);
      // The second bumped the op id, so the first (slower) load aborted.
      expect(sim.audioPlaying, isTrue);
      expect(sim.opId, 2);
    });
  });
}
