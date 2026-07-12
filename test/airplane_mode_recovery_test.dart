import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'package:radio_crestin/appAudioHandler.dart';

/// Reproduction + regression suite for the "audio doesn't come back after
/// airplane mode" bug.
///
/// Pre-fix flow when airplane-mode toggled within 8 seconds of a successful
/// HLS load:
///   1. NetworkService emits isOffline=true → buffer drains → player stalls
///   2. NetworkService emits isOffline=false (network back)
///   3. listener waits 2000ms, then calls reconnectIfNeeded()
///   4. reconnectIfNeeded sees lastSuccessfulLoadAt within 8s debounce
///      → silently skips → user sees "audio never came back"
///
/// Post-fix:
///   - Network-restore trigger explicitly bypasses the just-loaded debounce
///     (it's a real reconnect signal, not AVPlayer's PDT-decoder noise)
///   - Reconnect delay dropped 2000ms → 500ms (DNS settle floor)
///   - Buffering stall escalation dropped 15s → 3s
void main() {
  group('ReconnectPolicy timing constants', () {
    test('justLoadedDebounce is 8 seconds (AVPlayer PDT-decoder window)', () {
      expect(ReconnectPolicy.justLoadedDebounce,
          equals(const Duration(seconds: 8)));
    });

    test('networkRestoreReconnectDelay is 500ms (was 2000ms — pre-fix bug)',
        () {
      expect(ReconnectPolicy.networkRestoreReconnectDelay,
          equals(const Duration(milliseconds: 500)));
      expect(
        ReconnectPolicy.networkRestoreReconnectDelay.inMilliseconds,
        lessThan(1000),
        reason: 'Spotify-tier resume requires sub-1s recovery on network '
            'restore; longer delays were the dominant contributor to '
            'perceived "stream is delayed"',
      );
    });

    test('bufferingStallTimeout is 3 seconds (was 15s — too long)', () {
      expect(ReconnectPolicy.bufferingStallTimeout,
          equals(const Duration(seconds: 3)));
    });
  });

  group('ReconnectPolicy.shouldReconnect — guard clauses', () {
    final now = DateTime.now();
    DateTime? noLoad; // ignore: unused_local_variable

    test('no station → no reconnect', () {
      expect(
        ReconnectPolicy.shouldReconnect(
          trigger: ReconnectTrigger.networkRestored,
          now: now,
          lastSuccessfulLoadAt: null,
          processingState: ProcessingState.idle,
          playing: false,
          hasStation: false,
          hasBeenPlayed: true,
          isConnecting: false,
          isCasting: false,
        ),
        isFalse,
      );
    });

    test('already connecting → no reconnect (avoid pile-on)', () {
      expect(
        ReconnectPolicy.shouldReconnect(
          trigger: ReconnectTrigger.networkRestored,
          now: now,
          lastSuccessfulLoadAt: null,
          processingState: ProcessingState.idle,
          playing: false,
          hasStation: true,
          hasBeenPlayed: true,
          isConnecting: true,
          isCasting: false,
        ),
        isFalse,
      );
    });

    test('user never tapped play → no reconnect (no implicit autoplay)', () {
      expect(
        ReconnectPolicy.shouldReconnect(
          trigger: ReconnectTrigger.networkRestored,
          now: now,
          lastSuccessfulLoadAt: null,
          processingState: ProcessingState.idle,
          playing: false,
          hasStation: true,
          hasBeenPlayed: false,
          isConnecting: false,
          isCasting: false,
        ),
        isFalse,
      );
    });

    test('casting → no reconnect (Cast owns playback, local intentionally idle)',
        () {
      expect(
        ReconnectPolicy.shouldReconnect(
          trigger: ReconnectTrigger.networkRestored,
          now: now,
          lastSuccessfulLoadAt: null,
          processingState: ProcessingState.idle,
          playing: false,
          hasStation: true,
          hasBeenPlayed: true,
          isConnecting: false,
          isCasting: true,
        ),
        isFalse,
      );
    });
  });

  group('ReconnectPolicy.shouldReconnect — debounce bypass (the bug)', () {
    final now = DateTime.now();
    final twoSecondsAgo = now.subtract(const Duration(seconds: 2));
    final tenSecondsAgo = now.subtract(const Duration(seconds: 10));

    bool call(ReconnectTrigger trigger, {required DateTime? lastLoad}) {
      return ReconnectPolicy.shouldReconnect(
        trigger: trigger,
        now: now,
        lastSuccessfulLoadAt: lastLoad,
        processingState: ProcessingState.buffering,
        playing: true,
        hasStation: true,
        hasBeenPlayed: true,
        isConnecting: false,
        isCasting: false,
      );
    }

    test(
        'BUG REPRODUCTION: lifecycleResumed within debounce → no-op '
        '(this is the protection against AVPlayer PDT noise)', () {
      expect(call(ReconnectTrigger.lifecycleResumed, lastLoad: twoSecondsAgo),
          isFalse);
    });

    test(
        'FIX: networkRestored within debounce → STILL reconnects '
        '(network drops are not AVPlayer noise — they are real)', () {
      expect(call(ReconnectTrigger.networkRestored, lastLoad: twoSecondsAgo),
          isTrue,
          reason: 'Pre-fix this returned false; the 8s debounce ate the '
              'network-restore signal when airplane-mode was toggled '
              'within 8s of a successful load. The debounce only exists '
              'to ignore AVPlayer\'s transient post-load flickers — a '
              'real connectivity_plus event must always be respected.');
    });

    test(
        'FIX: bufferingStall within debounce → STILL reconnects '
        '(we already waited 3s, this is escalation not noise)', () {
      expect(call(ReconnectTrigger.bufferingStall, lastLoad: twoSecondsAgo),
          isTrue);
    });

    test('terminalState within debounce → no-op (debounce honored)', () {
      expect(call(ReconnectTrigger.terminalState, lastLoad: twoSecondsAgo),
          isFalse);
    });

    test('lifecycleResumed past debounce → reconnects', () {
      expect(call(ReconnectTrigger.lifecycleResumed, lastLoad: tenSecondsAgo),
          isTrue);
    });

    test('terminalState past debounce → reconnects', () {
      expect(call(ReconnectTrigger.terminalState, lastLoad: tenSecondsAgo),
          isTrue);
    });

    test('any trigger with no prior load → reconnects', () {
      for (final t in ReconnectTrigger.values) {
        expect(call(t, lastLoad: null), isTrue,
            reason: '$t must reconnect when lastSuccessfulLoadAt is null');
      }
    });
  });

  group('ReconnectPolicy.shouldReconnect — stalled / want-to-play detection',
      () {
    final now = DateTime.now();
    final pastDebounce = now.subtract(const Duration(seconds: 30));

    bool call({
      required ProcessingState state,
      required bool playing,
    }) {
      return ReconnectPolicy.shouldReconnect(
        trigger: ReconnectTrigger.networkRestored,
        now: now,
        lastSuccessfulLoadAt: pastDebounce,
        processingState: state,
        playing: playing,
        hasStation: true,
        hasBeenPlayed: true,
        isConnecting: false,
        isCasting: false,
      );
    }

    test('idle + playing=false → reconnects (typical post-airplane-mode case)',
        () {
      expect(call(state: ProcessingState.idle, playing: false), isTrue);
    });

    test('buffering + playing=true → reconnects (stalled)', () {
      expect(call(state: ProcessingState.buffering, playing: true), isTrue);
    });

    test('ready + playing=false → reconnects (user wants play but isn\'t)',
        () {
      // Covers AVPlayer sitting in `ready` with stale source after a failed
      // reload chain — the user-perceived "audio never came back" symptom.
      expect(call(state: ProcessingState.ready, playing: false), isTrue);
    });

    test('ready + playing=true → no-op (everything is fine)', () {
      expect(call(state: ProcessingState.ready, playing: true), isFalse);
    });

    test(
        'buffering + playing=false + hasBeenPlayed=true → reconnects '
        '(playing dropped to false unexpectedly — AVPlayer interruption '
        'that did not auto-resume)', () {
      // User-paused is represented by hasBeenPlayed=false (set by pause()),
      // so playing=false WITH hasBeenPlayed=true means "user wanted play
      // but the player gave up". The policy treats this as a stall.
      expect(call(state: ProcessingState.buffering, playing: false), isTrue);
    });

    test(
        'user paused (hasBeenPlayed=false) → no-op even on network restore',
        () {
      // Verifies the regression-prevention case the advisor flagged: when
      // user pauses, _hasBeenPlayed is cleared, and network restoration
      // must not auto-resume them.
      expect(
        ReconnectPolicy.shouldReconnect(
          trigger: ReconnectTrigger.networkRestored,
          now: now,
          lastSuccessfulLoadAt: pastDebounce,
          processingState: ProcessingState.ready,
          playing: false,
          hasStation: true,
          hasBeenPlayed: false, // user paused
          isConnecting: false,
          isCasting: false,
        ),
        isFalse,
      );
    });
  });

  group('ReconnectTrigger taxonomy', () {
    test('all four triggers are defined', () {
      expect(ReconnectTrigger.values, containsAll([
        ReconnectTrigger.networkRestored,
        ReconnectTrigger.bufferingStall,
        ReconnectTrigger.lifecycleResumed,
        ReconnectTrigger.terminalState,
      ]));
    });
  });

  // ── Fix 1: position-advancement watchdog ────────────────────────────────
  group('ReconnectPolicy.shouldReconnectFrozenPosition', () {
    final now = DateTime.now();
    final wellPastGrace =
        now.subtract(const Duration(seconds: 30)); // outside 12s grace
    final frozenLongEnough =
        now.subtract(const Duration(seconds: 15)); // past 10s frozen timeout

    bool call({
      bool playing = true,
      ProcessingState state = ProcessingState.ready,
      bool hasLiveStreamLoaded = true,
      bool isCasting = false,
      bool isVideoMode = false,
      DateTime? lastAdvance,
      DateTime? lastLoadOrSeek,
    }) {
      return ReconnectPolicy.shouldReconnectFrozenPosition(
        playing: playing,
        processingState: state,
        hasLiveStreamLoaded: hasLiveStreamLoaded,
        isCasting: isCasting,
        isVideoMode: isVideoMode,
        now: now,
        lastPositionAdvanceAt: lastAdvance ?? frozenLongEnough,
        lastLoadOrSeekAt: lastLoadOrSeek ?? wellPastGrace,
      );
    }

    test('frozen past timeout while ready+playing → reconnect (the bug)', () {
      expect(call(), isTrue);
    });

    test('position advanced recently → no-op', () {
      expect(call(lastAdvance: now.subtract(const Duration(seconds: 3))),
          isFalse);
    });

    test('paused → no-op', () {
      expect(call(playing: false), isFalse);
    });

    test('buffering → no-op (buffering stall timer owns it)', () {
      expect(call(state: ProcessingState.buffering), isFalse);
    });

    test('within load/seek grace → no-op (initial buffer fill is legit)', () {
      expect(call(lastLoadOrSeek: now.subtract(const Duration(seconds: 5))),
          isFalse);
    });

    test('casting → no-op', () {
      expect(call(isCasting: true), isFalse);
    });

    test('video/playlist mode → no-op', () {
      expect(call(isVideoMode: true), isFalse);
    });

    test('no live stream loaded → no-op', () {
      expect(call(hasLiveStreamLoaded: false), isFalse);
    });

    test('watchdog thresholds are window-independent time constants', () {
      expect(ReconnectPolicy.positionFrozenTimeout,
          const Duration(seconds: 10));
      expect(ReconnectPolicy.positionWatchdogInterval,
          const Duration(seconds: 5));
      // Grace must exceed the frozen timeout so a slow-but-legit start does
      // not trip the watchdog on its first evaluation.
      expect(
        ReconnectPolicy.positionFrozenGrace,
        greaterThan(ReconnectPolicy.positionFrozenTimeout),
      );
    });
  });

  // ── Fix 2: re-anchor on stale resume ────────────────────────────────────
  group('ReconnectPolicy.shouldReloadAfterPause', () {
    const twoMin = Duration(minutes: 2);
    const fiveMin = Duration(minutes: 5);
    const sixMinWindow = Duration(minutes: 6);
    const tenMinWindow = Duration(minutes: 10);

    test('instant mode (offset 0) → never reload (no window risk)', () {
      expect(
        ReconnectPolicy.shouldReloadAfterPause(
          offset: Duration.zero,
          windowDepth: sixMinWindow,
          pausedFor: const Duration(minutes: 30),
        ),
        isFalse,
      );
    });

    test('2-min offset / 6-min window: 60s pause resumes in place', () {
      // runway = 6−2 = 4min; safe = 0.6×240s = 144s. 60s (the disconnect
      // horizon) < 144s → fast resume, no behaviour change for the default.
      expect(
        ReconnectPolicy.shouldReloadAfterPause(
          offset: twoMin,
          windowDepth: sixMinWindow,
          pausedFor: const Duration(seconds: 60),
        ),
        isFalse,
      );
    });

    test('5-min offset / 6-min window: 40s pause forces reload (thin runway)',
        () {
      // runway = 6−5 = 1min; safe = 0.6×60s = 36s. 40s > 36s → reload.
      expect(
        ReconnectPolicy.shouldReloadAfterPause(
          offset: fiveMin,
          windowDepth: sixMinWindow,
          pausedFor: const Duration(seconds: 40),
        ),
        isTrue,
      );
    });

    test('5-min offset / 10-min window: 60s pause resumes in place', () {
      // runway = 10−5 = 5min; safe = 0.6×300s = 180s. 60s < 180s → resume.
      expect(
        ReconnectPolicy.shouldReloadAfterPause(
          offset: fiveMin,
          windowDepth: tenMinWindow,
          pausedFor: const Duration(seconds: 60),
        ),
        isFalse,
      );
    });

    test('unknown window depth → conservative fixed fallback', () {
      expect(
        ReconnectPolicy.shouldReloadAfterPause(
          offset: fiveMin,
          windowDepth: null,
          pausedFor: ReconnectPolicy.fastResumeMaxPauseFallback,
        ),
        isTrue,
      );
      expect(
        ReconnectPolicy.shouldReloadAfterPause(
          offset: fiveMin,
          windowDepth: null,
          pausedFor: const Duration(seconds: 1),
        ),
        isFalse,
      );
    });

    test('offset ≥ window depth → conservative fixed fallback', () {
      // Playhead already at/behind the trailing edge — can't trust the runway
      // computation, so fall back to the fixed budget.
      expect(
        ReconnectPolicy.shouldReloadAfterPause(
          offset: fiveMin,
          windowDepth: fiveMin,
          pausedFor: ReconnectPolicy.fastResumeMaxPauseFallback,
        ),
        isTrue,
      );
    });
  });
}
