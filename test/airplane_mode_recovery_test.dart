import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/hls_health_watchdog_flag.dart';
import 'package:radio_crestin/services/hls_timeline.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/stream_failover.dart';

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

  group('ReconnectPolicy.retryBackoff', () {
    const fiveSeconds = Duration(seconds: 5);

    test('online keeps the failover backoff', () {
      expect(ReconnectPolicy.retryBackoff(fiveSeconds, offline: false),
          fiveSeconds);
    });

    test('offline waits for the network instead of churning the player', () {
      expect(ReconnectPolicy.retryBackoff(fiveSeconds, offline: true),
          ReconnectPolicy.offlineRetryDelay);
      expect(ReconnectPolicy.offlineRetryDelay,
          greaterThan(StreamFailover.maxCycleBackoff));
    });

    test('the first pass over the streams always runs, even offline', () {
      // A wrong offline signal must never block a tap.
      expect(ReconnectPolicy.retryBackoff(Duration.zero, offline: true),
          Duration.zero);
    });
  });

  group('ReconnectPolicy.waitsForNetwork', () {
    final now = DateTime(2026, 10, 13, 12);

    bool waits(ConnectionStatus status, [Duration? withoutInternetFor]) =>
        ReconnectPolicy.waitsForNetwork(
          status: status,
          noInternetSince: withoutInternetFor == null
              ? null
              : now.subtract(withoutInternetFor),
          now: now,
        );

    test('without any network: waits', () {
      expect(waits(ConnectionStatus.offline), isTrue);
    });

    test('online: never waits', () {
      expect(waits(ConnectionStatus.online), isFalse);
    });

    test('a young outage on a live network keeps the usual pace', () {
      // Its attempts are the best check there is.
      expect(waits(ConnectionStatus.noInternet, const Duration(minutes: 1)),
          isFalse);
    });

    test('an outage past the patience waits like without a network', () {
      expect(
          waits(ConnectionStatus.noInternet,
              ReconnectPolicy.noInternetPatience),
          isTrue);
    });
  });

  group('ReconnectPolicy.failedPassBlamesStation', () {
    final start = DateTime(2026, 10, 13, 12);

    bool blames({
      bool startedOffline = false,
      bool offlineNow = false,
      DateTime? lastOfflineAt,
    }) =>
        ReconnectPolicy.failedPassBlamesStation(
          startedAt: start,
          startedOffline: startedOffline,
          offlineNow: offlineNow,
          lastOfflineAt: lastOfflineAt,
        );

    test('a pass online throughout blames the station', () {
      expect(blames(), isTrue);
      expect(
          blames(lastOfflineAt: start.subtract(const Duration(minutes: 1))),
          isTrue,
          reason: 'an outage before the pass is over');
    });

    test('a pass that started offline does not', () {
      // E.g. a tap while offline, the network back mid-pass: the error
      // would show just before the audio starts.
      expect(blames(startedOffline: true), isFalse);
    });

    test('a pass that ends offline does not', () {
      expect(blames(offlineNow: true), isFalse);
    });

    test('a pass during which the internet was lost and back does not', () {
      expect(blames(lastOfflineAt: start.add(const Duration(seconds: 2))),
          isFalse);
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

  // ── Fix 1: live-HLS liveness rules (replaces the position watchdog) ─────
  group('ReconnectPolicy.liveHlsStall', () {
    final now = DateTime.utc(2026, 10, 11, 12);
    DateTime ago(num seconds) =>
        now.subtract(Duration(milliseconds: (seconds * 1000).round()));
    Duration secs(num s) => Duration(milliseconds: (s * 1000).round());

    /// h1 at 137 s (2-min offset, healthy): the playhead 138 s behind the
    /// newest media, the edge grew 3 s ago, a segment loaded 2 s ago. The
    /// old watchdog fired here: `player.position` was capped at `duration`.
    LiveHlsHealthSample healthy({
      int? playheadSeq = 1000,
      double? edgeLag = 138,
      int? windowFirstSeq = 920,
      bool windowReset = false,
      DateTime? originAdvancedAt,
      Duration? originStaleFor,
      Duration? originUnreachableFor,
      double? edgeLagAtStall,
      DateTime? bufferedChangedAt,
      DateTime? advancingSince,
    }) =>
        LiveHlsHealthSample(
          playheadSeq: playheadSeq,
          edgeLagSeconds: edgeLag,
          windowFirstSeq: windowFirstSeq,
          windowReset: windowReset,
          originAdvancedAt: originAdvancedAt ?? ago(3),
          originStaleFor: originStaleFor,
          originUnreachableFor: originUnreachableFor,
          edgeLagAtStall: edgeLagAtStall,
          bufferedChangedAt: bufferedChangedAt ?? ago(2),
          advancingSince: advancingSince ?? ago(135),
          targetDuration: 6,
        );

    LiveHlsStall call(
      LiveHlsHealthSample s, {
      bool playing = true,
      ProcessingState state = ProcessingState.ready,
      bool hasLiveHlsLoaded = true,
      bool isCasting = false,
      bool isVideoOrPlaylistMode = false,
      bool silentStallPossible = true,
    }) =>
        ReconnectPolicy.liveHlsStall(
          playing: playing,
          processingState: state,
          hasLiveHlsLoaded: hasLiveHlsLoaded,
          isCasting: isCasting,
          isVideoOrPlaylistMode: isVideoOrPlaylistMode,
          silentStallPossible: silentStallPossible,
          now: now,
          s: s,
        );

    test('healthy 2-min playback at 137 s → none (the old false freeze)', () {
      expect(call(healthy()), LiveHlsStall.none);
    });

    test('healthy instant / 5-min geometries → none', () {
      expect(call(healthy(edgeLag: 18)), LiveHlsStall.none);
      expect(call(healthy(edgeLag: 318, windowFirstSeq: 948)),
          LiveHlsStall.none);
    });

    group('evicted', () {
      test('playhead 2 segments before the window → evicted', () {
        expect(call(healthy(playheadSeq: 918)), LiveHlsStall.evicted);
      });

      test('within the 1-segment margin → none', () {
        expect(call(healthy(playheadSeq: 919)), LiveHlsStall.none);
        expect(call(healthy(playheadSeq: 920)), LiveHlsStall.none);
      });

      test('a window reset (sequence restart) → evicted', () {
        expect(call(healthy(windowReset: true)), LiveHlsStall.evicted);
      });
    });

    group('pastLiveEdge', () {
      LiveHlsHealthSample stale({
        required double edgeLag,
        Duration? staleFor,
        double edgeLagAtStall = 100,
      }) =>
          healthy(
            edgeLag: edgeLag,
            originAdvancedAt: ago(120),
            originStaleFor: staleFor ?? secs(100),
            edgeLagAtStall: edgeLagAtStall,
          );

      test('proven stale origin: fires at 5 target durations (±1 s)', () {
        expect(call(stale(edgeLag: 29)), LiveHlsStall.pastLiveEdge);
        expect(call(stale(edgeLag: 30)), LiveHlsStall.pastLiveEdge);
        expect(call(stale(edgeLag: 31)), LiveHlsStall.none);
      });

      test('normal geometry needs only proven staleness (≥ 3 TD)', () {
        expect(call(stale(edgeLag: 20, staleFor: secs(18))),
            LiveHlsStall.pastLiveEdge);
      });

      test(
          'near-edge geometry fires once the playhead ran one target '
          'duration past the published media (±1 s)', () {
        LiveHlsHealthSample nearEdge(num edgeLag) =>
            stale(edgeLag: edgeLag.toDouble(), edgeLagAtStall: 18);
        expect(call(nearEdge(5)), LiveHlsStall.none,
            reason: 'media left: the player still plays');
        expect(call(nearEdge(-5)), LiveHlsStall.none);
        expect(call(nearEdge(-6)), LiveHlsStall.pastLiveEdge);
        expect(call(nearEdge(-7)), LiveHlsStall.pastLiveEdge);
      });

      test('staleness never proven (only failed polls) → no fire', () {
        expect(
            call(healthy(
                edgeLag: 0, originAdvancedAt: ago(40), originStaleFor: null)),
            LiveHlsStall.none);
      });

      LiveHlsHealthSample dead(num unreachable, {num? loadedAgo}) => healthy(
          edgeLag: 25,
          originAdvancedAt: ago(unreachable + 5),
          originUnreachableFor: secs(unreachable),
          bufferedChangedAt: ago(loadedAgo ?? unreachable));

      test('origin unreachable (polls failing) for 45 s (±1 s)', () {
        expect(call(dead(44)), LiveHlsStall.none);
        expect(call(dead(45)), LiveHlsStall.pastLiveEdge);
        expect(call(dead(46)), LiveHlsStall.pastLiveEdge);
      });

      test(
          'failed polls alone never fire: the player must have stopped '
          'loading for 45 s too (±1 s)', () {
        expect(call(dead(120, loadedAgo: 4)), LiveHlsStall.none);
        expect(call(dead(120, loadedAgo: 44)), LiveHlsStall.none);
        expect(call(dead(120, loadedAgo: 45)), LiveHlsStall.pastLiveEdge);
      });
    });

    group('starving', () {
      LiveHlsHealthSample starving(num stagnant, {num originAge = 7}) =>
          healthy(
              bufferedChangedAt: ago(stagnant),
              originAdvancedAt: ago(originAge));

      test('buffer stagnant 45 s while the origin publishes (±1 s)', () {
        expect(call(starving(44)), LiveHlsStall.none);
        expect(call(starving(45)), LiveHlsStall.starving);
        expect(call(starving(46)), LiveHlsStall.starving);
      });

      test('only while the origin is fresh (advanced ≤ 30 s ago)', () {
        expect(call(starving(60, originAge: 30)), LiveHlsStall.starving);
        expect(call(starving(60, originAge: 31)), LiveHlsStall.none);
      });
    });

    test('Android (silentStallPossible: false) never stalls: a_jump and '
        'a_stale geometries', () {
      // a_jump: playhead 113 s (19 segments) before the truncated window.
      expect(
          call(healthy(playheadSeq: 901), silentStallPossible: false),
          LiveHlsStall.none);
      // a_stale: origin stale 91 s, playhead 29 s before the newest media.
      expect(
          call(
              healthy(
                  edgeLag: 29,
                  originAdvancedAt: ago(91),
                  originStaleFor: secs(91),
                  edgeLagAtStall: 120),
              silentStallPossible: false),
          LiveHlsStall.none);
      expect(call(healthy(bufferedChangedAt: ago(60)),
              silentStallPossible: false),
          LiveHlsStall.none);
    });

    test('grace, paused, buffering, casting, video, not loaded, unanchored → '
        'none', () {
      final evicting = healthy(playheadSeq: 900);
      expect(call(evicting), LiveHlsStall.evicted, reason: 'control');
      expect(
          call(healthy(playheadSeq: 900, advancingSince: ago(19))),
          LiveHlsStall.none);
      expect(
          call(healthy(playheadSeq: 900, advancingSince: ago(20))),
          LiveHlsStall.evicted);
      expect(call(evicting, playing: false), LiveHlsStall.none);
      expect(call(evicting, state: ProcessingState.buffering),
          LiveHlsStall.none);
      expect(call(evicting, isCasting: true), LiveHlsStall.none);
      expect(call(evicting, isVideoOrPlaylistMode: true), LiveHlsStall.none);
      expect(call(evicting, hasLiveHlsLoaded: false), LiveHlsStall.none);
      expect(call(healthy(playheadSeq: null)), LiveHlsStall.none);
    });

    test('thresholds and cadence', () {
      expect(ReconnectPolicy.liveHlsWatchdogInterval,
          const Duration(seconds: 5));
      expect(ReconnectPolicy.liveHlsGrace, const Duration(seconds: 20));
      expect(ReconnectPolicy.pastEndTargetDurations, 1);
      expect(ReconnectPolicy.originUnreachableAfter,
          const Duration(seconds: 45));
      expect(ReconnectPolicy.deadOriginBufferStagnantAfter,
          const Duration(seconds: 45));
      expect(ReconnectPolicy.starvingAfter, const Duration(seconds: 45));
      expect(ReconnectPolicy.originFreshWithin, const Duration(seconds: 30));
      expect(ReconnectPolicy.pastLiveEdgeTargetDurations, 5);
    });
  });

  group('LiveHlsStallRecovery (escalation)', () {
    final t0 = DateTime.utc(2026, 10, 11, 12);
    DateTime at(int s) => t0.add(Duration(seconds: s));
    const url = 'https://hls.radiocrestin.ro/hls/rve-suceava/index.m3u8';
    const instant = Duration.zero;
    const twoMin = Duration(minutes: 2);
    const fiveMin = Duration(minutes: 5);

    LiveHlsRecoveryAction fire(
      LiveHlsStallRecovery r,
      int s, {
      LiveHlsStall stall = LiveHlsStall.pastLiveEdge,
      Duration offset = instant,
      String station = 's',
      String fireUrl = url,
    }) =>
        r.decide(
            stall: stall,
            url: fireUrl,
            station: station,
            offset: offset,
            now: at(s));

    test('first pastLiveEdge/starving fire reloads; a repeat within 3 min '
        'fails over', () {
      final r = LiveHlsStallRecovery();
      expect(fire(r, 0), LiveHlsRecoveryAction.reloadSameStream);
      expect(fire(r, 60, stall: LiveHlsStall.starving),
          LiveHlsRecoveryAction.failOverAndReload);
    });

    test('a fire more than 3 min after the previous one reloads again', () {
      final r = LiveHlsStallRecovery();
      fire(r, 0);
      expect(fire(r, 181), LiveHlsRecoveryAction.reloadSameStream);
    });

    test('the repeat window covers the stale audio a reload replays', () {
      expect(LiveHlsStallRecovery.repeatWindowFor(instant),
          const Duration(minutes: 3));
      expect(LiveHlsStallRecovery.repeatWindowFor(twoMin),
          const Duration(minutes: 4));
      expect(LiveHlsStallRecovery.repeatWindowFor(fiveMin),
          const Duration(minutes: 7));
    });

    test(
        '5-min listener on a frozen origin: each reload replays ~270 s of '
        'stale audio, and the repeat fire still fails over', () {
      // A reload seeks 300 s behind the frozen edge; pastLiveEdge needs the
      // playhead within 5 TD (30 s) again: 270 s of playback, plus grace,
      // the tick and the load.
      final r = LiveHlsStallRecovery();
      expect(fire(r, 0, offset: fiveMin),
          LiveHlsRecoveryAction.reloadSameStream);
      expect(fire(r, 290, offset: fiveMin),
          LiveHlsRecoveryAction.failOverAndReload);
      // A 2-min listener's repeat comes ~95 s later; 4 min still covers it.
      final r2 = LiveHlsStallRecovery();
      fire(r2, 0, offset: twoMin);
      expect(fire(r2, 230, offset: twoMin),
          LiveHlsRecoveryAction.failOverAndReload);
      expect(fire(r2, 480, offset: twoMin),
          LiveHlsRecoveryAction.reloadSameStream);
    });

    test('evicted never fails over (the stream is healthy)', () {
      final r = LiveHlsStallRecovery();
      for (var i = 0; i < 4; i++) {
        expect(fire(r, 40 * i, stall: LiveHlsStall.evicted),
            LiveHlsRecoveryAction.reloadSameStream);
      }
    });

    test('rate limit: one liveness reload per 30 s per station', () {
      final r = LiveHlsStallRecovery();
      fire(r, 0, stall: LiveHlsStall.evicted);
      expect(fire(r, 29, stall: LiveHlsStall.starving),
          LiveHlsRecoveryAction.none);
      expect(
          fire(r, 29,
              stall: LiveHlsStall.starving,
              station: 'other',
              fireUrl: 'https://hls.radiocrestin.ro/hls/other/index.m3u8'),
          LiveHlsRecoveryAction.reloadSameStream);
      expect(fire(r, 30, stall: LiveHlsStall.starving),
          LiveHlsRecoveryAction.reloadSameStream);
    });

    test('none → none', () {
      expect(fire(LiveHlsStallRecovery(), 0, stall: LiveHlsStall.none),
          LiveHlsRecoveryAction.none);
    });
  });

  group('HlsHealthWatchdogFlag (kill switch)', () {
    test('an undefined flag keeps the watchdog on; a defined one decides', () {
      expect(HlsHealthWatchdogFlag.isEnabled(flagExists: false), isTrue);
      expect(
          HlsHealthWatchdogFlag.isEnabled(flagExists: true, flagOn: true),
          isTrue);
      expect(
          HlsHealthWatchdogFlag.isEnabled(flagExists: true, flagOn: false),
          isFalse);
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

    test('real live windows (Darwin 642 s, ExoPlayer 660 s): the 60 s '
        'disconnect comes first at 2 min; 5 min reloads after ~205 s', () {
      const windows = [Duration(seconds: 642), Duration(seconds: 660)];
      for (final window in windows) {
        // 2 min: runway 522-540 s → budget 313-324 s, never reached before
        // the 60 s pause disconnect.
        expect(
          ReconnectPolicy.shouldReloadAfterPause(
            offset: twoMin,
            windowDepth: window,
            pausedFor: const Duration(seconds: 60),
          ),
          isFalse,
        );
        expect(
          ReconnectPolicy.shouldReloadAfterPause(
            offset: twoMin,
            windowDepth: window,
            pausedFor: const Duration(seconds: 313),
          ),
          isFalse,
        );
      }
      expect(
        ReconnectPolicy.shouldReloadAfterPause(
          offset: fiveMin,
          windowDepth: const Duration(seconds: 642),
          pausedFor: const Duration(seconds: 206),
        ),
        isTrue,
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
