import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kDebugMode, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/performance_monitor.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:flutter_airplay/flutter_airplay.dart' as flutter_airplay;
import 'package:radio_crestin/services/image_cache_service.dart';
import 'package:radio_crestin/services/android_auto_browse.dart';
import 'package:radio_crestin/services/car_play_layout.dart';
import 'package:radio_crestin/services/car_play_service.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/cast_service.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart' show CastMediaPlayerState;
import 'package:radio_crestin/tv/tv_platform.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/playback_failure.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/retry_log_throttle.dart';
import 'package:radio_crestin/services/review_service.dart';
import 'package:radio_crestin/services/silence_keeper.dart';
import 'package:radio_crestin/services/sleep_timer_service.dart';
import 'package:radio_crestin/services/song_history_service.dart';
import 'package:radio_crestin/services/hls_health_watchdog_flag.dart';
import 'package:radio_crestin/services/hls_hold_proxy.dart';
import 'package:radio_crestin/services/hls_hold_proxy_flag.dart';
import 'package:radio_crestin/services/hls_start_variant.dart';
import 'package:radio_crestin/services/hls_timeline.dart';
import 'package:radio_crestin/services/ios_background_task.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/stream_failover.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/services/video_mode_decision.dart';
import 'package:radio_crestin/services/playlist_controller.dart';
import 'package:radio_crestin/types/playlist_item.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/utils.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';
import 'globals.dart' as globals;

/// Why a [reconnectIfNeeded] call was issued. Controls whether the
/// "just successfully loaded" debounce applies.
///
/// AVPlayer occasionally misreports `completed` / `idle-while-playing`
/// in the first ~8s after a successful HLS load (PDT-decoder confusion).
/// To avoid a reload loop, lifecycle/terminal-state triggers are debounced.
/// A network drop+restore is not debounced: it is a real reconnect signal,
/// not a flicker. (A sustained buffering stall replays directly, see
/// [ReconnectPolicy.bufferingStallTimeout].)
enum ReconnectTrigger {
  networkRestored,    // NetworkService.isOffline true → false (bypass debounce)
  lifecycleResumed,   // App returned to foreground (honor debounce)
  terminalState,      // processingState == completed/idle (honor debounce)
}

/// Why the live-HLS liveness watchdog decided the stream went silent.
/// Returned by [ReconnectPolicy.liveHlsStall].
enum LiveHlsStall {
  none,

  /// The playhead's segment left the server window (ffmpeg restart, window
  /// reset): the stream is healthy, only our playhead is outside it.
  evicted,

  /// The origin stopped publishing and the playhead reached the end of the
  /// published media (frozen playlist, playlist errors).
  pastLiveEdge,

  /// The origin publishes but no new media loads (segments failing).
  starving,
}

/// What to do about a liveness fire. See [LiveHlsStallRecovery].
enum LiveHlsRecoveryAction {
  /// Nothing this tick (rate-limited).
  none,

  /// Reload the stream without marking it failed.
  reloadSameStream,

  /// Mark the stream failed (failover skips it) and reload.
  failOverAndReload,
}

/// Pure escalation policy for liveness fires.
///
/// A single fire must not fail a stream over: one `recordFailure` makes the
/// next load skip HLS for 90 s, which is the very symptom the old position
/// watchdog produced. The first `pastLiveEdge` / `starving` fire for a URL
/// reloads it; only a repeat within [repeatWindowFor] the listening offset
/// records the failure. `evicted` never does (the stream is fine). Reloads
/// are rate-limited per station.
class LiveHlsStallRecovery {
  /// Shortest repeat window (instant and 2-min geometry).
  static const Duration repeatWindow = Duration(minutes: 3);

  /// Slack on top of the offset: grace (20 s), the staleness proof (~20 s),
  /// the 5-TD edge margin (30 s), and poll and tick granularity (15 s).
  static const Duration repeatMargin = Duration(minutes: 2);

  static const Duration minReloadInterval = Duration(seconds: 30);

  final Map<String, DateTime> _lastFireByUrl = {};
  final Map<String, DateTime> _lastReloadByStation = {};

  /// How long a repeat fire still counts as the same fault.
  ///
  /// A reload seeks [offset] behind the edge again, so on a frozen origin
  /// the listener first replays [offset] of stale audio before the same
  /// rule can fire: a fixed 3 min would treat every 5-min repeat as a first
  /// fire and reload a dead origin forever.
  static Duration repeatWindowFor(Duration offset) {
    final scaled = offset + repeatMargin;
    return scaled > repeatWindow ? scaled : repeatWindow;
  }

  /// [offset] is the listener's seek offset behind the live edge.
  LiveHlsRecoveryAction decide({
    required LiveHlsStall stall,
    required String url,
    required String station,
    required Duration offset,
    required DateTime now,
  }) {
    if (stall == LiveHlsStall.none) return LiveHlsRecoveryAction.none;
    _forget(now, repeatWindowFor(offset));
    final lastReload = _lastReloadByStation[station];
    if (lastReload != null && now.difference(lastReload) < minReloadInterval) {
      return LiveHlsRecoveryAction.none;
    }
    _lastReloadByStation[station] = now;
    if (stall == LiveHlsStall.evicted) {
      return LiveHlsRecoveryAction.reloadSameStream;
    }
    final repeated = _lastFireByUrl.containsKey(url);
    _lastFireByUrl[url] = now;
    return repeated
        ? LiveHlsRecoveryAction.failOverAndReload
        : LiveHlsRecoveryAction.reloadSameStream;
  }

  void _forget(DateTime now, Duration window) {
    _lastFireByUrl.removeWhere((_, t) => now.difference(t) >= window);
    _lastReloadByStation
        .removeWhere((_, t) => now.difference(t) >= minReloadInterval);
  }
}

/// The start ([resumed] false) or the end ([resumed] true) of a load pause
/// the live-HLS watchdog rides out. See [LiveHlsLoadPauses].
class LiveHlsLoadPauseEvent {
  final bool resumed;

  /// Seconds without a load: so far at the start, in all at the end.
  final double seconds;

  /// Buffer ahead of the playhead: at the start, or what was left when
  /// the player loaded again.
  final double? bufferedAheadSeconds;

  const LiveHlsLoadPauseEvent({
    required this.resumed,
    required this.seconds,
    this.bufferedAheadSeconds,
  });
}

/// Follows the load pauses the live-HLS watchdog rides out (see
/// [ReconnectPolicy.isLoadPause]) for the log: how long iPhones pause, and
/// how low the buffer gets before they load again (see
/// [ReconnectPolicy.starvingBufferFloor]). Pure: [tick] takes the time.
class LiveHlsLoadPauses {
  ({DateTime since, double? ahead, DateTime at})? _pause;

  /// Forgets the pause in progress: a new load, or playback stopped, which
  /// would read as buffer drained.
  void reset() => _pause = null;

  /// The watchdog tick at [now]: the start of a pause (once per pause) or
  /// its end, the first buffer growth after it. [playing]: playing and
  /// ready.
  LiveHlsLoadPauseEvent? tick(
    LiveHlsHealthSample s,
    DateTime now, {
    required bool playing,
  }) {
    final since = s.bufferedChangedAt;
    final pause = _pause;
    if (pause != null) {
      if (since == null || !since.isAfter(pause.since)) {
        _pause = (since: pause.since, ahead: s.bufferedAheadSeconds, at: now);
        return null;
      }
      _pause = null;
      final ahead = pause.ahead;
      return LiveHlsLoadPauseEvent(
        resumed: true,
        seconds: _seconds(since.difference(pause.since)),
        // The last estimate, drained by the playing since.
        bufferedAheadSeconds:
            ahead == null ? null : ahead - _seconds(since.difference(pause.at)),
      );
    }
    if (since == null || !playing || !ReconnectPolicy.isLoadPause(s, now)) {
      return null;
    }
    _pause = (since: since, ahead: s.bufferedAheadSeconds, at: now);
    return LiveHlsLoadPauseEvent(
      resumed: false,
      seconds: _seconds(now.difference(since)),
      bufferedAheadSeconds: s.bufferedAheadSeconds,
    );
  }

  static double _seconds(Duration d) => d.inMilliseconds / 1000;
}

/// Pure fast-start tuning policy: how much the player buffers before it
/// begins (or resumes) playback.
///
/// The just_audio player is a single instance shared by live radio/TV and VOD
/// playlist items, so its load configuration is global and tuned for live.
/// These values are the single source of truth used both when constructing
/// the player and in tests.
class FastStartConfig {
  /// Android `bufferForPlaybackDuration` for live: lowered from 3s so ExoPlayer
  /// starts ~1.5s sooner. Safe because the 50s `minBufferDuration`, the 2s
  /// post-rebuffer threshold, and the reconnect/stall machinery still cover the
  /// rebuffer risk — this only moves the "ok to start" line, not the fill goal.
  static const Duration liveAndroidBufferForPlayback =
      Duration(milliseconds: 1500);

  /// iOS/macOS `automaticallyWaitsToMinimizeStalling` for live sources. Must
  /// stay true, like VOD. With false, a resumed live stream (after a pause or
  /// an interruption) can go silent while AVPlayer stays `ready`, so the app
  /// shows it playing until the user pauses and plays again. 45d02e0 reverted
  /// false for that; 474dec6 brought it back for ~20 ms of faster start. The
  /// silence keep-alive does not cover it: it starts on buffering, which this
  /// state never reports. A compile-time const for the const player config.
  static const bool liveDarwinAutomaticallyWaits = true;
}

/// Pure decision policy for whether to issue a reconnect attempt now.
/// Extracted from [AppAudioHandler.reconnectIfNeeded] so the timing rules
/// are unit-testable without spinning up a real [AudioPlayer].
class ReconnectPolicy {
  /// AVPlayer can transiently report terminal states (completed / idle)
  /// during PDT-decoder confusion in the first few seconds after a
  /// successful HLS load. Without this debounce we re-issue play() every
  /// ~3s and create a visible reload loop ("Attempt → Loaded → Rebuffer").
  ///
  /// Only honored for [ReconnectTrigger.lifecycleResumed] and
  /// [ReconnectTrigger.terminalState] — those are the triggers that
  /// genuinely fire on AVPlayer noise. A real network drop+restore is not
  /// noise; suppressing it was the root cause of "audio doesn't come back after airplane mode" when
  /// the toggle happened within 8s of a successful load.
  static const Duration justLoadedDebounce = Duration(seconds: 8);

  /// Delay between the internet answering again and the reconnect check.
  ///
  /// `NetworkService.isOffline` turns false only once a probe or a request
  /// got through, so there is no DNS to wait for: the delay lets a network
  /// that drops again at once settle first (the check is skipped if it
  /// did). Was 2000ms, the dominant contributor to "stream restart is
  /// delayed" UX.
  static const Duration networkRestoreReconnectDelay =
      Duration(milliseconds: 500);

  /// Backoff between failed retry cycles while there is no network at all.
  ///
  /// Every attempt fails at once then, so the play loop waits for a network
  /// to come back (which wakes the wait early) instead of building a new
  /// player every 10s; a network that does come back without answering
  /// keeps the usual backoff, its attempts being the best check there is.
  /// The wait is a safety net, should the no-network signal be wrong.
  static const Duration offlineRetryDelay = Duration(seconds: 30);

  /// The wait before a retry cycle: [base] (see `StreamFailover.retryDelay`),
  /// stretched to [offlineRetryDelay] while [offline] (no network at all).
  /// The first pass over the streams ([base] zero) always runs, so a wrong
  /// offline signal never blocks a tap.
  static Duration retryBackoff(Duration base, {required bool offline}) =>
      base > Duration.zero && offline ? offlineRetryDelay : base;

  /// How long a network without internet keeps the usual retry pace: while
  /// an outage is young, the attempts are the best check there is; past
  /// that, a new player every 10s only costs (CPU, analytics, battery).
  static const Duration noInternetPatience = Duration(minutes: 2);

  /// Whether the retry loop waits [offlineRetryDelay] between passes: with
  /// no network at all, or no internet for over [noInternetPatience] (since
  /// [noInternetSince]). The internet coming back wakes the wait either way.
  static bool waitsForNetwork({
    required ConnectionStatus status,
    required DateTime? noInternetSince,
    required DateTime now,
  }) =>
      status == ConnectionStatus.offline ||
      (status == ConnectionStatus.noInternet &&
          noInternetSince != null &&
          now.difference(noInternetSince) >= noInternetPatience);

  /// Whether a pass over the streams that failed blames the station, and
  /// so deserves an error: only if the internet was up for all of it.
  ///
  /// Started offline ([startedOffline]), offline now ([offlineNow]), or
  /// lost in between ([lastOfflineAt] after [startedAt]): the loads failed
  /// for want of internet, which the offline banner already says.
  static bool failedPassBlamesStation({
    required DateTime startedAt,
    required bool startedOffline,
    required bool offlineNow,
    required DateTime? lastOfflineAt,
  }) =>
      !startedOffline &&
      !offlineNow &&
      (lastOfflineAt == null || !lastOfflineAt.isAfter(startedAt));

  /// Reattempt play() after this much continuous buffering. Was 15s;
  /// dropped to 3s to match Spotify-tier perceived recovery. play() has
  /// its own retry chain (cycles the station's stream URLs endlessly with
  /// capped backoff — see [StreamFailover]), so a fast retry here just
  /// shortens the silence window — it does not bypass any safety net.
  static const Duration bufferingStallTimeout = Duration(seconds: 3);

  /// How often the live-HLS liveness rules ([liveHlsStall]) are evaluated.
  static const Duration liveHlsWatchdogInterval = Duration(seconds: 5);

  /// No liveness rule fires this soon after playback (re)started advancing:
  /// initial fill, seek settle, resume. Also spans at least two polls.
  static const Duration liveHlsGrace = Duration(seconds: 20);

  /// `evicted` margin behind the window's first segment, absorbing the
  /// poll granularity. Measured playhead lag at a real eviction: 131.7 s.
  static const int evictedMarginSegments = 1;

  /// AVPlayer stops ~29.5 s (≈ 5 target durations) before the end of a
  /// frozen playlist (measured f1/f4), so `pastLiveEdge` fires within 5 TD
  /// of the newest published media — at about the real death.
  static const int pastLiveEdgeTargetDurations = 5;

  /// Instant / near-edge geometry (the playhead already within 5 TD of the
  /// edge when the stall was proven): `pastLiveEdge` fires once the playhead
  /// ran this many target durations past the newest published media.
  ///
  /// Measured (review R1.6, macOS AVPlayer at offset 0, runs i1/i5/i6): the
  /// player plays to the very end of the published media (0.2 s left) and
  /// then stays silent for good, even when the playlist grows again 7 or 22 s
  /// later (rate 0 for the remaining 2 min while its buffer refilled). So a
  /// stall shorter than the 18 s hold-back never gets here, and one that
  /// does has already silenced the player. One TD absorbs a projected
  /// anchor's error (< 1 segment).
  static const int pastEndTargetDurations = 1;

  /// Playlist polls failing for this long (two or more in a row) count as a
  /// dead origin for `pastLiveEdge` (playlist 503: silent at f4 t=189.5).
  static const Duration originUnreachableAfter = Duration(seconds: 45);

  /// A dead origin also needs the player's own loading to have stopped for
  /// this long, so failed app polls alone (our request failing while the
  /// player's succeed) never fire: near the live edge, where this rule
  /// applies, the forward buffer can never fill, and AVPlayer moves its
  /// buffered position at least every 6.2 s (measured). Same value as
  /// [starvingAfter].
  static const Duration deadOriginBufferStagnantAfter = Duration(seconds: 45);

  /// Native buffered position unchanged for this long while the origin
  /// keeps publishing: new segments may not load. Only [starving] once the
  /// buffer is also nearly played out (see [starvingBufferFloor]).
  static const Duration starvingAfter = Duration(seconds: 45);

  /// A load stalled for [starvingAfter] is [starving] only once less than
  /// this is left in the buffer.
  ///
  /// With a full forward buffer an iPhone on mobile data may load nothing
  /// for over a minute (measured on an iPhone 13: nothing loaded for 65 s
  /// from 126 s buffered, 73 s still left when the stall rule fired), while
  /// the Mac and the simulator top it up every segment. Reloading then
  /// threw away a minute of healthy audio and restarted behind it. 20 s
  /// covers the 5 s watchdog tick and a segment of error in the estimate
  /// (see `HlsPlayheadClock.itemPositionAt`) before the audio runs out.
  /// The cost: an AVPlayer gone silent with a full buffer, still reporting
  /// playing, is reloaded only once the estimate drains to here.
  static const Duration starvingBufferFloor = Duration(seconds: 20);

  /// `starving` only when the origin published within this window.
  static const Duration originFreshWithin = Duration(seconds: 30);

  /// Whether this platform's player can go silent while just_audio still
  /// reports ready+playing. Only AVPlayer does: just_audio ignores
  /// `AVPlayerTimeControlStatusPaused`. ExoPlayer turns the same origin
  /// faults into idle/error/buffering, which the existing paths handle, or
  /// rides through them inaudibly; evicting it from a healthy buffer would
  /// only cause a needless reload (measured).
  static bool get silentStallPossible => Platform.isIOS || Platform.isMacOS;

  /// Shortest outage after which a live HLS stream still playing from its
  /// buffer is checked for loading again once the internet is back (see
  /// [outageCheckDelay]).
  ///
  /// AVPlayer retries a live playlist that fails to load for a while, then
  /// gives up: it loads nothing more, however long the network has been
  /// back, until its buffer runs dry, and then restarts at the live point,
  /// skipping what the 2- or 5-minute offset kept. macOS 27 gives up ~30 s
  /// after its first failure (15 and 25 s outages resumed at once, 35 s to
  /// 280 s ones never did), an iPhone 13 on mobile data (iOS 27) after
  /// about 100 s (20, 60 and two of three 100 s outages resumed at once;
  /// 150, 200 and 280 s ones never did). No call the app can make wakes it
  /// up: seeks, pause and play, or the load settings it can change.
  static const Duration outageCheckAfter = Duration(seconds: 20);

  /// How long the player gets, once the internet answers again, to load
  /// by itself. One still retrying loads as the network comes back: the
  /// iPhone did before the app's own probe answered, macOS retries every
  /// 5 s. One that had not by then never did, watched for 2 minutes.
  static const Duration outageResumeGrace = Duration(seconds: 8);

  /// What is left of the buffer when the check runs at the latest, so it
  /// runs before AVPlayer's own restart at the live point.
  static const Duration outageCheckBufferMargin = Duration(seconds: 4);

  /// How long after the internet came back to check that a live HLS stream
  /// still playing from its buffer after an outage of [outage] loads again;
  /// null when the outage was too short for the player to give up.
  ///
  /// [bufferedAhead], what the player has left (null: unknown), brings the
  /// check forward so it runs before the buffer runs dry.
  static Duration? outageCheckDelay({
    required Duration outage,
    required Duration? bufferedAhead,
  }) {
    if (outage < outageCheckAfter) return null;
    if (bufferedAhead == null) return outageResumeGrace;
    final latest = bufferedAhead - outageCheckBufferMargin;
    if (latest <= Duration.zero) return Duration.zero;
    return latest < outageResumeGrace ? latest : outageResumeGrace;
  }

  /// Fraction of the trailing-edge runway we let elapse while paused before
  /// forcing a reload (re-anchor) instead of resuming in place. 0.6 leaves a
  /// 40% cushion for segment granularity and clock skew, so we reload well
  /// before the paused playhead's segment is evicted from the DVR window.
  static const double fastResumeRunwayFraction = 0.6;

  /// Fallback max pause when the live window depth is unknown. Conservative:
  /// with a 5-min offset in a ~6-min window the trailing-edge runway can be
  /// as little as ~60s, so a stale playhead goes bad fast.
  static const Duration fastResumeMaxPauseFallback = Duration(seconds: 45);

  /// Which liveness rule, if any, says the live HLS stream went silent while
  /// just_audio still reports ready + playing. Pure: [now] is passed in.
  ///
  /// Every rule reads the media-time playhead and the app's own successful
  /// polls, never `player.position` (an extrapolation capped at `duration`,
  /// which froze ~10 s after every behind-live seek and failed over healthy
  /// streams). Gated on [silentStallPossible], playing + ready, a local live
  /// HLS stream, an anchored playhead and [liveHlsGrace].
  static LiveHlsStall liveHlsStall({
    required bool playing,
    required ProcessingState processingState,
    required bool hasLiveHlsLoaded,
    required bool isCasting,
    required bool isVideoOrPlaylistMode,
    required bool silentStallPossible,
    required DateTime now,
    required LiveHlsHealthSample s,
  }) {
    if (!silentStallPossible || !playing) return LiveHlsStall.none;
    if (processingState != ProcessingState.ready) return LiveHlsStall.none;
    if (!hasLiveHlsLoaded || isCasting || isVideoOrPlaylistMode) {
      return LiveHlsStall.none;
    }
    final since = s.advancingSince;
    final seq = s.playheadSeq;
    if (since == null || seq == null) return LiveHlsStall.none;
    if (now.difference(since) < liveHlsGrace) return LiveHlsStall.none;
    if (_isEvicted(s, seq)) return LiveHlsStall.evicted;
    if (_isPastLiveEdge(s, now)) return LiveHlsStall.pastLiveEdge;
    if (_isStarving(s, now)) return LiveHlsStall.starving;
    return LiveHlsStall.none;
  }

  /// The playhead's segment left the server window (or the sequence
  /// restarted): AVPlayer stays at rate 1 outside its loaded ranges.
  static bool _isEvicted(LiveHlsHealthSample s, int playheadSeq) {
    if (s.windowReset) return true;
    final first = s.windowFirstSeq;
    return first != null && playheadSeq < first - evictedMarginSegments;
  }

  /// The origin stopped publishing and the playhead reached the end of the
  /// published media.
  static bool _isPastLiveEdge(LiveHlsHealthSample s, DateTime now) {
    final lag = s.edgeLagSeconds;
    final td = s.targetDuration;
    if (lag == null || lag > pastLiveEdgeTargetDurations * td) return false;
    if (_isOriginDead(s, now)) return true;
    if (s.originStaleFor == null) return false;
    final atStall = s.edgeLagAtStall;
    final nearEdge =
        atStall == null || atStall < pastLiveEdgeTargetDurations * td;
    return !nearEdge || lag <= -pastEndTargetDurations * td;
  }

  /// Our polls fail and the player loads nothing either.
  static bool _isOriginDead(LiveHlsHealthSample s, DateTime now) {
    final unreachable = s.originUnreachableFor;
    final bufferedAt = s.bufferedChangedAt;
    return unreachable != null &&
        unreachable >= originUnreachableAfter &&
        bufferedAt != null &&
        now.difference(bufferedAt) >= deadOriginBufferStagnantAfter;
  }

  /// The origin keeps publishing, the player loads nothing, and its buffer
  /// is nearly played out.
  static bool _isStarving(LiveHlsHealthSample s, DateTime now) =>
      _loadStalled(s, now) && !_bufferOutlastsStall(s);

  /// Whether the player loaded nothing for [starvingAfter] while the origin
  /// published, yet more than [starvingBufferFloor] is still buffered: a
  /// load pause, not a fault. The watchdog logs it once per pause.
  static bool isLoadPause(LiveHlsHealthSample s, DateTime now) =>
      _loadStalled(s, now) && _bufferOutlastsStall(s);

  /// The wait counts from the later of the last buffer growth and our last
  /// failed poll: while our polls fail too, the device is cut off (a tunnel),
  /// and once the network is back the player needs a few seconds to resume
  /// loading. Counting the outage would reload a healthy stream right then.
  static bool _loadStalled(LiveHlsHealthSample s, DateTime now) {
    final bufferedAt = s.bufferedChangedAt;
    final advancedAt = s.originAdvancedAt;
    if (bufferedAt == null || advancedAt == null) return false;
    final failedAt = s.pollFailedAt;
    final stagnantSince =
        failedAt != null && failedAt.isAfter(bufferedAt) ? failedAt : bufferedAt;
    return now.difference(stagnantSince) >= starvingAfter &&
        now.difference(advancedAt) <= originFreshWithin;
  }

  /// An unknown buffer (not anchored) never holds a fire back.
  static bool _bufferOutlastsStall(LiveHlsHealthSample s) {
    final ahead = s.bufferedAheadSeconds;
    return ahead != null &&
        ahead > starvingBufferFloor.inMicroseconds / 1e6;
  }

  /// Returns true when a paused live-HLS stream has aged past the point where
  /// resuming in place is safe, so `play()` should reload and re-anchor behind
  /// the live edge instead of fast-resuming. Pure function.
  ///
  /// The danger is the sliding DVR window's trailing (oldest) edge catching up
  /// to the paused playhead: the playhead sits [offset] behind live, so it has
  /// roughly `windowDepth - offset` of runway before its segment is evicted;
  /// while paused the trailing edge advances one second per wall-clock second.
  /// [windowDepth] is `player.duration` on the live stream (the window length).
  static bool shouldReloadAfterPause({
    required Duration offset,
    required Duration? windowDepth,
    required Duration pausedFor,
  }) {
    // Instant mode (offset 0) and direct/non-windowed streams have no
    // trailing-edge risk — always safe to resume in place.
    if (offset <= Duration.zero) return false;
    if (windowDepth == null || windowDepth <= offset) {
      // Unknown depth, or the playhead is already at/behind the window's
      // trailing edge — fall back to a conservative fixed budget.
      return pausedFor >= fastResumeMaxPauseFallback;
    }
    final runway = windowDepth - offset;
    return pausedFor >= runway * fastResumeRunwayFraction;
  }

  /// Returns true when the player should be told to reconnect right now.
  /// Pure function: no I/O, no clock side-effects (caller passes [now]).
  static bool shouldReconnect({
    required ReconnectTrigger trigger,
    required DateTime now,
    required DateTime? lastSuccessfulLoadAt,
    required ProcessingState processingState,
    required bool playing,
    required bool hasStation,
    required bool hasBeenPlayed,
    required bool isConnecting,
    required bool isCasting,
  }) {
    if (!hasStation) return false;
    if (isConnecting) return false;
    // No play() ever succeeded — recovery would just kick a fresh load
    // for a station the user never asked to play.
    if (!hasBeenPlayed) return false;
    // Cast owns playback; the local player is intentionally idle.
    if (isCasting) return false;

    final honorsDebounce = trigger == ReconnectTrigger.lifecycleResumed ||
        trigger == ReconnectTrigger.terminalState;
    if (honorsDebounce && lastSuccessfulLoadAt != null) {
      if (now.difference(lastSuccessfulLoadAt) < justLoadedDebounce) {
        return false;
      }
    }

    final stalled = processingState == ProcessingState.idle ||
        (processingState == ProcessingState.buffering && playing);
    // User intent says play but the player isn't — covers the
    // post-airplane-mode case where AVPlayer sits in `ready` with a
    // stale source after a failed reload chain.
    final shouldBePlayingButIsnt = !playing;
    return stalled || shouldBePlayingButIsnt;
  }
}

/// Describes why a station connection failed.
enum ConnectionErrorReason {
  timeout,    // Stream didn't load within the allowed time
  network,    // No internet or DNS failure (SocketException)
  httpError,  // Server returned an error (404, 403, 500, etc.)
  unknown,    // Other / unclassifiable error
}

class ConnectionError {
  final String stationName;
  final ConnectionErrorReason reason;
  final String? details; // e.g. "404" or the raw error message

  const ConnectionError({
    required this.stationName,
    required this.reason,
    this.details,
  });
}

/// Snapshot of the currently loaded stream. Drives the diagnostic UI in
/// Settings and is included in PostHog `listening_*` events so sessions can
/// be correlated with stream switches.
class StreamInfo {
  final String url;
  final String? type;        // 'HLS', 'proxied_stream', etc. — from station_streams.type
  final int attemptIndex;    // 0-based index into the station's stream list
  final int totalStreams;
  final String stationSlug;
  final String stationTitle;
  final DateTime loadedAt;

  const StreamInfo({
    required this.url,
    required this.type,
    required this.attemptIndex,
    required this.totalStreams,
    required this.stationSlug,
    required this.stationTitle,
    required this.loadedAt,
  });

  String get host {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }
}

enum StreamEventKind {
  attempt,            // play() trying to load a stream
  loaded,             // setAudioSource succeeded
  failed,             // setAudioSource raised
  switched,           // loaded URL differs from previous loaded URL
  hlsCompleted,       // HLS reported processingState == completed
  nonHlsCompleted,    // direct MP3 completed (treated as error)
  lostIdle,           // processingState == idle while playing
  bufferingStall,     // buffering exceeded long-stall threshold (15s)
  bufferingDrop,      // brief rebuffer (>=100ms): the audible-glitch case
  playerError,        // playbackEventStream raised (error not tied to load attempt)
  audioInterruption,  // AVAudioSession interruption begin/end (route change, call, lock)
  lifecycle,          // app lifecycle transitions (resumed/inactive/paused/hidden)
  hlsStalled,         // live HLS silent while reported playing (liveness)
}

/// Lightweight event record kept in a capped ring buffer for the in-app
/// diagnostic view.
class StreamEvent {
  final DateTime timestamp;
  final StreamEventKind kind;
  final String message;

  const StreamEvent({
    required this.timestamp,
    required this.kind,
    required this.message,
  });
}

/// How much AVPlayer may load ahead of the playhead: what plays through a
/// network drop.
///
/// AVPlayer loads only up to the live edge, so the listening offset sets
/// the buffer (measured on the Mac, topped up every segment): ~18 s live,
/// ~120 s at 2 minutes, ~300 s at 5 minutes. The cap must clear the
/// longest offset: at 120 s the 5-minute mode kept only 2 minutes and went
/// silent 2 minutes into an outage. 30 s of margin for the latency that
/// rebuffers add. An iPhone on mobile data may still load nothing for over
/// a minute once it is full (see [ReconnectPolicy.starvingBufferFloor]).
const Duration darwinForwardBuffer = Duration(minutes: 5, seconds: 30);

Future<AppAudioHandler> initAudioService({required graphqlClient}) async {
  final AudioPlayer player = AudioPlayer(
    // TODO: enable userAgent to identify users
    // Currently it's disabled because it creates an insecure proxy on localhost to add this header
    // and it's needs more configuration
    // userAgent: 'radiocrestinapp/1.0 (Linux;Android 11) https://www.radio-crestin.com',
    // The handler pauses and resumes for interruptions and route
    // disconnects itself (see AppAudioHandler._onAudioInterruption).
    handleInterruptions: false,
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(seconds: 50),
        maxBufferDuration: Duration(minutes: 10),
        // Fast-start: 1.5s (was 3s). ~all app playback is live radio/TV, so the
        // global value is tuned for live via FastStartConfig. Rebuffer risk is
        // still covered by the 50s minBuffer, the 2s post-rebuffer threshold,
        // and the reconnect/stall machinery. (Android is reasoning-verified —
        // not measurable on the iOS test rig.)
        bufferForPlaybackDuration: FastStartConfig.liveAndroidBufferForPlayback,
        // 2s (was 5s): post-rebuffer is exactly when we need fast resume —
        // every extra second here is silence the user hears after a
        // network blip. ExoPlayer still re-fills minBufferDuration in the
        // background; this only controls the "ok to start playing again"
        // threshold.
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 2),
      ),
      androidLivePlaybackSpeedControl: AndroidLivePlaybackSpeedControl(
        fallbackMinPlaybackSpeed: 1.0,
        fallbackMaxPlaybackSpeed: 1.0,
      ),
      darwinLoadControl: DarwinLoadControl(
        canUseNetworkResourcesForLiveStreamingWhilePaused: true,
        // See FastStartConfig.liveDarwinAutomaticallyWaits for why this must
        // not be false.
        automaticallyWaitsToMinimizeStalling:
            FastStartConfig.liveDarwinAutomaticallyWaits,
        preferredForwardBufferDuration: darwinForwardBuffer,
      ),
    ),
  );
  // On Android TV the ongoing media notification is undesirable. We can't drop
  // the foreground service — it's what keeps audio playing continuously in the
  // background — but we route TV to a dedicated notification channel that
  // MainActivity pre-creates at IMPORTANCE_MIN, so the notification is
  // suppressed from view while playback is unaffected. Phones keep the normal
  // media notification on the default channel. (Channel importance can't be
  // lowered after creation, so TV uses its own fresh channel id.)
  final bool isAndroidTv = TvPlatform.isAndroidTV;
  return await AudioService.init(
    builder: () {
      return AppAudioHandler(player: player, graphqlClient: graphqlClient);
    },
    config: AudioServiceConfig(
      androidNotificationChannelId: isAndroidTv
          ? 'com.radiocrestin.radio_crestin.channel.tv'
          : 'com.radiocrestin.radio_crestin.channel',
      androidNotificationChannelName: 'Radio Crestin',
      androidNotificationIcon: "drawable/ic_launcher_foreground",
      androidNotificationOngoing: true,
      notificationColor: const Color(0xffe91e63),
      // Only the queue reads this flag, and nothing uses the preloaded
      // files: Android Auto downloads queue art itself, iOS ignores the
      // queue. Lock-screen art is loaded independently of it.
      preloadArtwork: false,
      // androidShowNotificationBadge: true,
      androidStopForegroundOnPause: true,
      androidBrowsableRootExtras: const {
        'android.media.browse.CONTENT_STYLE_SUPPORTED': true,
        'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 1, // list
        'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1, // list
        'android.media.browse.SEARCH_SUPPORTED': true,
      },
    ),
  );
}

// https://github.com/ryanheise/audio_service/blob/master/audio_service/example/lib/main.dart
// https://github.com/ryanheise/audio_service/blob/81bb480ac2aeaec08cd61c62765529613db60837/audio_service/example/lib/example_playlist.dart
class AppAudioHandler extends BaseAudioHandler {
  final GraphQLClient graphqlClient;
  final StationDataService stationDataService = GetIt.instance<StationDataService>();

  // Track loaded stream to avoid unnecessary reconnection on pause/resume
  String? _loadedStreamUrl;
  String? _loadedStreamType;
  String? get loadedStreamType => _loadedStreamType;
  // True while play() is loading a new source — keeps broadcast in loading state
  // to prevent spinner flash between setAudioSource() and player.play().
  bool _isConnecting = false;
  bool get isPlayingOrConnecting => player.playing || _isConnecting;

  /// Whether the player's `ready` right after a play() predates it.
  ///
  /// AVPlayer first waits for data, then plays: just_audio reports that
  /// wait as buffering (15–130 ms on an iPhone), but only 10–25 ms after
  /// play(), keeping the pre-play `ready` until then. ExoPlayer is ready
  /// only with data to play, and plays at once.
  @visibleForTesting
  static bool playerWaitsAfterPlay = Platform.isIOS || Platform.isMacOS;

  /// Whether live HLS loads of the origin go through the local hold proxy
  /// ([HlsHoldProxy]), which keeps AVPlayer from giving up on a playlist an
  /// outage keeps failing. iOS only: ExoPlayer rides outages out by itself,
  /// and macOS is not in scope.
  @visibleForTesting
  static bool holdProxyPlatform = Platform.isIOS;

  /// Whether a pause of a live HLS stream holds iOS background time
  /// ([IosBackgroundTask]) until the resume.
  ///
  /// iOS suspends an app paused in the background within seconds, and
  /// AVPlayer then drops everything it had loaded ahead: the resume loads
  /// again from the network, and without one has nothing to play, although
  /// the 2 or 5 minutes ahead were loaded (iPhone 13, iOS 27: a 40 s pause
  /// in the background emptied the buffer, with or without the hold proxy;
  /// with the app kept running, it kept all of it). The time iOS grants
  /// (~30 s) covers the short pauses: a car or headphones disconnecting, a
  /// call, Siri. Silence would keep the app running longer, but iOS then
  /// shows the pause button on the lock screen and in CarPlay.
  @visibleForTesting
  static bool pausedStreamBackgroundTimePlatform = Platform.isIOS;

  // Set by _playPlayer() while the player's `ready` predates the play (see
  // playerWaitsAfterPlay): _broadcastState reports buffering for it, so
  // the play button keeps its spinner until audio comes out. Ends with the
  // player's first event since the play (see _endAwaitingAudioStart).
  bool _awaitingAudioStart = false;
  // When the player was asked to play; null while play() runs.
  DateTime? _audioStartRequestedAt;

  /// Whether the local player is putting out audio: playing, with data to
  /// play (not buffering, loading or idle). Emits on change only.
  Stream<bool> get audioPlayingStream => player.playerStateStream
      .map((s) => s.playing && s.processingState == ProcessingState.ready)
      .distinct();
  bool get isCarConnected => GetIt.instance.isRegistered<CarPlayService>() &&
      GetIt.instance<CarPlayService>().isConnected;
  bool get isCasting => GetIt.instance.isRegistered<CastService>() &&
      GetIt.instance<CastService>().isCasting.value;

  /// The local player has a live HLS stream loaded (playing, paused or
  /// buffering): its now-playing must follow the audible timeline.
  bool get _isLocalLiveHls =>
      _loadedStreamType == 'HLS' && !_videoMode && !_playlistMode && !isCasting;
  // The listener's play intent in every local mode (station, video,
  // playlist): set by playStation(), play() and entering video mode (which
  // autoplays), cleared by pause(), stop(), an error stop and a Cast
  // disconnect. Reconnects and the background video handoff only act while
  // it is set.
  bool _hasBeenPlayed = false;

  /// Whether the listener wants audio playing: set by a play, cleared by a
  /// pause, a stop or an error stop (see the field above).
  bool get hasPlayIntent => _hasBeenPlayed;

  /// Tells the media session that playback waits for the internet
  /// ([shown]), or no longer does.
  ///
  /// Android Auto shows a session in the error state as its message in
  /// place of the player: what Google asks of a media app that cannot play
  /// without internet. Only while the listener wants audio: a pause still
  /// shows as a pause. When to call it is up to [OfflineAlertGate].
  void setOfflineError(bool shown) {
    if (shown == _offlineErrorShown) return;
    _offlineErrorShown = shown;
    _broadcastState(player.playbackEvent);
  }

  /// The listener asked for audio (see [playRequested]).
  void _onPlayRequested() {
    // A new attempt shows as loading; the error comes back only if this
    // attempt cannot play either. Cleared here, not by a listener of
    // [playRequested], which would hear of it after the next state.
    setOfflineError(false);
    playRequested.add(null);
  }

  /// play() is (re)connecting because the listener wants audio. The media
  /// session keeps reporting playing (and loading) meanwhile: the retry
  /// loop stops the player between attempts, and a session that says
  /// paused takes audio_service out of the foreground, which Android 12+
  /// does not let a backgrounded app re-enter
  /// (ForegroundServiceStartNotAllowedException). The app then loses the
  /// network and gets frozen, and the audio never comes back after a long
  /// drop with the phone in a pocket or on Android Auto.
  bool get _isReconnectingOnIntent => _isConnecting && _hasBeenPlayed;

  // Set while the car says that playback waits for the internet (see
  // setOfflineError); cleared by the next request for audio.
  bool _offlineErrorShown = false;

  // Set when an interruption paused playback so that its end resumes it;
  // cleared by any later play, pause or stop.
  bool _resumeAfterInterruption = false;
  // Set for the play() an interruption's end issues, so that resume is not
  // counted as a user action toward the review dialog.
  bool _isInterruptionResume = false;
  Timer? _disconnectTimer;

  // ── Live HLS timeline ────────────────────────────────────────────────
  // The audible clock (what the listener hears, in server wall-clock time),
  // origin progress for the liveness rules, and the song boundaries the
  // playlist announced. Fed by player events and the app's own playlist
  // poll; never by `player.position`, which is a duration-capped
  // extrapolation for live HLS.
  final HlsTimeline _hlsTimeline = HlsTimeline();
  final SongBoundaryQueue _songBoundaries = SongBoundaryQueue();
  final LiveHlsStallRecovery _liveHlsRecovery = LiveHlsStallRecovery();
  // One client for the 10 s playlist poll, so it reuses the keep-alive
  // connection (dart:io idles it out after 15 s) instead of paying a TCP +
  // TLS handshake per request. Created with the handler, so a test zone's
  // client is captured.
  final http.Client _hlsHttp = http.Client();
  Timer? _hlsPlaylistPollTimer;
  // One timer for the earliest pending song boundary.
  Timer? _songBoundaryTimer;
  // Anchor re-checks while the clock is not exactly anchored (settle tick,
  // snapshot retries, projection deadline). See [_armHlsAnchorChecks].
  Timer? _hlsAnchorTimer;
  int _hlsAnchorCheckIndex = 0;
  DateTime? _hlsAnchorRunStart;
  // Bumped on every (re)load and stop, so a playlist response that started
  // for a previous stream is discarded.
  int _hlsLoadGeneration = 0;
  // Android TV: the last METADATA-CHANGED instant seen (live refresh key).
  DateTime? _lastMetadataChangedAt;
  StreamSubscription<bool>? _castSessionSub;
  // Most recent ICY (SHOUTcast) `StreamTitle` for direct/MP3 streams.
  // Compared so the same title repeated by the player doesn't fire
  // duplicate metadata refreshes mid-song.
  String? _lastIcyTitle;
  Timer? _bufferingStallTimer;
  // Aliased to the canonical value in ReconnectPolicy so the test suite
  // can assert on a single source of truth.
  static const _bufferingStallTimeout = ReconnectPolicy.bufferingStallTimeout;

  // ── Live-HLS liveness watchdog (silent-stall safety net) ──────────────
  // AVPlayer can go silent while just_audio keeps reporting ready+playing
  // (frozen or failing playlist, window reset). This Darwin-only periodic
  // check evaluates [ReconnectPolicy.liveHlsStall] and reloads.
  Timer? _liveHlsWatchdogTimer;
  // The load pauses the watchdog rides out, for the log.
  final LiveHlsLoadPauses _loadPauses = LiveHlsLoadPauses();
  // When the player last stopped playing (pause, interruption, route
  // disconnect); null while playing. Freezes the approximate audible
  // instant (see _audibleInstant), and Fix 2 in play() measures the pause
  // from it to decide whether a fast resume would land on an evicted DVR
  // segment.
  DateTime? _stoppedPlayingAt;
  // The seek offset the loaded HLS stream was anchored with, so
  // reapplySeekOffset() can skip a reload that would not change it.
  Duration? _anchoredOffset;
  // Streams whose start variant (see HlsStartVariant) failed to load this
  // session while their index.m3u8 loaded, the origin not publishing the
  // variant yet: they load index.m3u8 and seek behind live, as before.
  final Set<String> _streamsWithoutStartVariant = {};

  // ── Hold proxy (iOS, see holdProxyPlatform) ───────────────────────────
  // Created at the first live HLS load of the origin. Each load through it
  // is a session of its own.
  HlsHoldProxy? _holdProxy;
  StreamSubscription<bool>? _holdProxyNetworkSub;
  // The proxy URL the loaded stream plays from; null when the player
  // loaded the stream's own URL. Set with _loadedStreamUrl, and only read
  // while that is set.
  String? _loadedProxyUrl;
  // Streams that loaded directly after their load through the proxy had
  // failed (see _mayBypassHoldProxy): they skip it until the device moves
  // to another network.
  final Set<String> _streamsWithoutHoldProxy = {};

  // ── Auto slow-connection escalation ───────────────────────────────────
  // Repeated stream trouble (buffering stalls / watchdog reconnects) within a
  // short window means the link can't sustain a small forward buffer, so we
  // escalate the seek offset to 5 minutes for subsequent (re)loads via
  // [SeekModeManager.changeAutoSlowConnection]. Timestamps of recent trouble;
  // pruned to [_slowConnectionWindow] on each record.
  final List<DateTime> _streamTroubleEvents = [];
  static const _slowConnectionWindow = Duration(minutes: 3);
  static const _slowConnectionTroubleThreshold = 3;

  // Never anchor the playhead closer than this to the window's trailing
  // (oldest) edge. A 5-min offset on a window only ~6 min deep would otherwise
  // land within seconds of the edge, where the segment is evicted almost
  // immediately. 75s comfortably exceeds the liveness watchdog's grace, so a
  // genuine stall is still caught rather than masked by a doomed anchor.
  // The origin clamps its start variants (HlsStartVariant) with the same
  // margin, so loading one lands where this seek would.
  static const _dvrTrailingSafetyMargin = Duration(seconds: 75);

  // ── Fast-start instrumentation (debug-mode only) ──────────────────────
  // Measures tap→first-audio: the stopwatch starts at playStation() entry and
  // is read when the player first advances position while playing. No-op in
  // release (guarded by kDebugMode) so it never costs the tap path in prod.
  Stopwatch? _fastStartWatch;
  String? _fastStartLabel; // 'AUDIO' | 'TV' | 'PLAYLIST'
  bool _fastStartDone = true;
  // Guards the one-shot connection pre-warm of the last-played station.
  bool _prewarmed = false;

  // ── iOS background-suspension keep-alive ──────────────────────────
  // When the main player enters `buffering` and audio output stops, iOS
  // gives the app ~30–60s before suspending it (even with the `audio`
  // background mode). Suspension freezes the entire Dart isolate, so
  // every reconnect/retry path stops working — the user hears silence
  // until they bring the app back to the foreground. To prevent that,
  // the SilenceKeeper loops inaudible audio on a second player whenever
  // the main player is buffering for more than _silenceKeepAliveDelay, and
  // keeps it on while play() reconnects for the listener (a failed attempt
  // starts it too), until audio comes out again or the listener pauses.
  // iOS sees continuous audio output and never suspends the engine, so
  // the recovery code (idle-while-playing, isOffline-restored, the
  // stall-timer reattempt) keeps running.
  late final SilenceKeeper _silenceKeeper = SilenceKeeper(log: _trace);
  Timer? _silenceKeepAliveStartTimer;
  static const _silenceKeepAliveDelay = Duration(seconds: 3);

  // Held from a pause of a live HLS stream to the resume, the disconnect or
  // a stop (see pausedStreamBackgroundTimePlatform).
  final IosBackgroundTask _pausedStreamTask = IosBackgroundTask();

  // Track every buffering enter/exit so short rebuffers (the audible-glitch
  // case) get logged. _bufferingStallTimer above is the long-stall escalation.
  // 250ms threshold: tried 100ms during the screen-lock investigation but
  // it surfaced sub-perceptual decoder reseeds the user wouldn't actually
  // hear, bloating the ring with noise that pushed real events out.
  static const _bufferingDropMinDuration = Duration(milliseconds: 250);
  DateTime? _bufferingStartedAt;
  Duration _bufferingStartPosition = Duration.zero;
  Duration? _bufferingStartAhead;
  // Dedup playbackEventStream errors so a sticky error doesn't spam the log.
  int? _lastPlayerErrorCode;
  String? _lastPlayerErrorMessage;
  // How often the last logged error came again since.
  int _playerErrorRepeats = 0;
  // Monotonically increasing ID to cancel stale play() operations.
  // Each playStation() increments this; play() checks it after every await
  // to bail out if a newer operation has superseded it.
  int _playOperationId = 0;
  // Bumped by playStation(), pause() and stop() only (not by play(), so a
  // lock-screen play during a switch does not cancel it). playStation()
  // re-checks it after each await: a newer switch, or a pause/stop, wins.
  int _stationSwitchId = 0;
  // Completer used to immediately break out of a stale setAudioSource() await
  // instead of waiting for the full 3-10s timeout to expire.
  Completer<void>? _sourceLoadCanceller;
  // Completed when the network returns, waking the play() loop's backoff
  // between failed retry cycles. Null while no backoff is pending.
  Completer<void>? _retryBackoffWake;
  // The station the running play() loop loads (see _isLoadingStation).
  Object? _loadingStationId;
  // Set when the network returns during the play() loop: its next attempt
  // starts a fresh pass at the preferred stream (see _wakeRetryBackoff).
  bool _restartPassAtPreferred = false;
  // Last buffered position seen, to tell buffer growth (data arriving).
  Duration _lastBufferedPosition = Duration.zero;
  // When the internet was last lost, so a failed pass that overlapped it
  // does not blame the station.
  DateTime? _lastOfflineAt;
  // The outage the loaded live HLS stream is checked for once the internet
  // is back (see _scheduleOutageLoadCheck): when it began, kept across a
  // network that drops again before the check so a flapping restore still
  // counts from the first loss (null: no outage to check); and, from the
  // last loss, the load playing (its generation), what it had buffered and
  // when it first loaded more.
  DateTime? _outageSince;
  int? _outageHlsGeneration;
  Duration _outageBufferedPosition = Duration.zero;
  DateTime? _outageLoadResumedAt;
  Timer? _outageLoadCheck;
  // Since when a network has been up without internet; null otherwise.
  DateTime? _noInternetSince;
  // The play() call (op id) whose connection error was shown, and the one
  // still deciding whether to show it: one error per play() call.
  int _errorShownForOp = -1;
  int _errorPendingForOp = -1;
  static const _disconnectDelay = Duration(seconds: 60);

  // ── Video mode & playlist state ───────────────────────────────────────
  // Video mode: media_kit (libmpv) is the single audio+video source for TV
  // channels and video playlist items, replacing just_audio while it runs.
  // See [VideoModeDecision] for when it engages. Playlist mode: a "playlist"
  // station is active and [PlaylistController] drives per-item playback.
  bool _videoMode = false;
  bool _playlistMode = false;
  // True while the active playlist item is a UI-owned YouTube entry (single
  // video or whole playlist). While set, `playbackState` reflects the inline
  // iframe (not the stopped just_audio player) and play/pause route to it.
  bool _playlistYoutubeActive = false;
  bool _youtubePlaying = false;
  Duration _youtubePosition = Duration.zero;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  final List<StreamSubscription<dynamic>> _videoSubs = [];
  // True while _handoffTvVideoToAudio() is leaving video mode. iOS
  // delivers `hidden` and `paused` back-to-back, and both would otherwise
  // pass the `_videoMode` guard and start two audio loads.
  bool _tvHandoffInFlight = false;
  StreamSubscription<bool>? _carRouteSub;
  StreamSubscription<bool>? _castRouteSub;

  // ── Video→audio fallback watchdog ──────────────────────────────────────
  // When video mode is engaged but the decoder never renders a first frame
  // (e.g. libmpv can't decode the codec on the iOS simulator → perpetual
  // buffering) or errors repeatedly, we hand off to the just_audio audio-only
  // pipeline for the same content and surface a "Doar audio" chip.
  Timer? _videoFallbackTimer;
  final List<StreamSubscription<dynamic>> _videoFallbackSubs = [];
  int _videoFallbackErrorCount = 0;
  // The URL we've fallen back to audio for. While set, video mode is NOT
  // re-attempted for it (so a foreground/resume handoff doesn't fight the
  // fallback), until different content starts.
  String? _fallenBackUrl;

  /// How long video mode may buffer without a first frame before we fall back
  /// to audio-only. Sits in the task's 8-10s window.
  static const Duration _videoFallbackTimeout = Duration(seconds: 9);

  /// Number of media_kit errors (before a first frame) that trips an immediate
  /// fallback rather than waiting out [_videoFallbackTimeout].
  static const int _videoFallbackMaxErrors = 2;

  /// Emits true when the current video content is playing audio-only because
  /// video rendering failed and we fell back. The UI shows a subtle "Doar
  /// audio" chip. Cleared when new/working video content starts.
  final BehaviorSubject<bool> audioOnlyFallback =
      BehaviorSubject<bool>.seeded(false);

  /// True while media_kit is the active source (UI shows the `Video` widget).
  bool get isVideoModeActive => _videoMode;

  /// True while a "playlist" station is active.
  bool get isPlaylistMode => _playlistMode;

  /// True while the app is foregrounded (drives the video-mode decision and
  /// the background→audio handoff). Updated by [onAppLifecycleChanged].
  bool get isForeground => _lifecycleState == AppLifecycleState.resumed;

  /// Emits true when playback is in video mode. The UI subscribes to know when
  /// to mount `Video(controller: videoService.controller)`.
  final BehaviorSubject<bool> isVideoMode = BehaviorSubject<bool>.seeded(false);

  /// The media_kit video service (audio+video). Exposed so the UI can read the
  /// `VideoController` for TV playback.
  VideoPlaybackService get videoService => GetIt.instance<VideoPlaybackService>();

  /// The "somn" timer. Lives here rather than in the player widget so it
  /// keeps running when the full player is collapsed or rebuilt.
  late final SleepTimerService sleepTimer = SleepTimerService(
    stopPlayback: stop,
    setVolume: _setOutputVolume,
    log: AnalyticsService.instance.log,
  );

  /// Applies [volume] (0..1) to every local engine that can be audible: the
  /// just_audio radio player and media_kit (TV, video and playlist items).
  Future<void> _setOutputVolume(double volume) async {
    await player.setVolume(volume);
    if (GetIt.instance.isRegistered<VideoPlaybackService>()) {
      await videoService.setVolume(volume);
    }
  }

  PlaylistController get _playlistController =>
      GetIt.instance<PlaylistController>();

  /// Invoked by [PlaylistController] when the current playlist AUDIO item (or a
  /// video item playing audio-only) reaches end-of-stream, so it can advance.
  VoidCallback? onPlaylistItemCompleted;

  /// Invoked by [PlaylistController] when the current playlist audio item fails
  /// to load, so it can advance to the next item.
  void Function(Object error)? onPlaylistItemError;

  // Track last emitted mediaItem fields to avoid redundant Android notification updates
  int? _lastEmittedSongId;

  final BehaviorSubject<Station?> currentStation = BehaviorSubject.seeded(null);

  /// Emits details when play() exhausts all retries and cannot connect.
  final PublishSubject<ConnectionError> connectionError = PublishSubject<ConnectionError>();

  /// Emits when the listener asks for audio: a station pick (list, search,
  /// link, next or previous, the car's autoplay) or a play after a pause
  /// or stop. Reconnects and interruption resumes act on a request already
  /// made and emit nothing.
  final PublishSubject<void> playRequested = PublishSubject<void>();
  final BehaviorSubject<List<MediaItem>> stationsMediaItems = BehaviorSubject.seeded(<MediaItem>[]);

  /// Currently loaded stream (null when stopped, paused-and-disconnected, or casting).
  final BehaviorSubject<StreamInfo?> currentStreamInfo = BehaviorSubject.seeded(null);

  /// Capped ring buffer of recent stream lifecycle events for in-app debugging.
  /// Most recent first; `_maxStreamEvents` keeps memory bounded.
  /// 60 entries: enough headroom to capture a full reload-loop investigation
  /// (every cycle is ~3 events: attempt + loaded + rebuffer, plus lifecycle
  /// + interruption noise) without truncating the trigger event.
  static const int _maxStreamEvents = 60;
  /// Aliased to the canonical value in [ReconnectPolicy].
  static const _terminalStateReloadDebounce = ReconnectPolicy.justLoadedDebounce;
  DateTime? _lastSuccessfulLoadAt;
  final BehaviorSubject<List<StreamEvent>> recentStreamEvents =
      BehaviorSubject.seeded(const <StreamEvent>[]);

  void _recordStreamEvent(StreamEventKind kind, String message) {
    final event = StreamEvent(
      timestamp: DateTime.now(),
      kind: kind,
      message: message,
    );
    final next = <StreamEvent>[event, ...recentStreamEvents.value];
    if (next.length > _maxStreamEvents) {
      next.removeRange(_maxStreamEvents, next.length);
    }
    recentStreamEvents.add(next);
  }

  /// Called when processingState transitions out of [ProcessingState.buffering].
  /// Records a `bufferingDrop` event when the rebuffer was perceptibly long
  /// (≥250ms) — below that threshold transitions are sub-perceptual decoder
  /// reseeding and would just add noise to the diagnostic log.
  void _recordBufferingExit(ProcessingState endState) {
    final startedAt = _bufferingStartedAt;
    if (startedAt == null) return;
    _bufferingStartedAt = null;
    final duration = DateTime.now().difference(startedAt);
    if (duration < _bufferingDropMinDuration) return;
    final positionEnd = player.position;
    final positionStart = _bufferingStartPosition;
    final bufferedAheadAtStart = _bufferingStartAhead;
    final lastInfo = currentStreamInfo.valueOrNull;
    _recordStreamEvent(
      StreamEventKind.bufferingDrop,
      'Rebuffer ${duration.inMilliseconds}ms — buf ${bufferedAheadAtStart?.inMilliseconds ?? '?'}ms ahead at start, end=${endState.name}',
    );
    AnalyticsService.instance.logWarning('stream buffering drop', {
      'station_slug': lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
      'station_id': currentStation.valueOrNull?.id,
      'stream_url': lastInfo?.url,
      'stream_type': lastInfo?.type,
      'stream_index': lastInfo?.attemptIndex,
      'total_streams': lastInfo?.totalStreams,
      'duration_ms': duration.inMilliseconds,
      'position_start_ms': positionStart.inMilliseconds,
      'position_end_ms': positionEnd.inMilliseconds,
      'buffered_ahead_at_start_ms': bufferedAheadAtStart?.inMilliseconds,
      'end_state': endState.name,
    });
  }

  /// Starts a buffering episode: when, where, and how much was buffered
  /// ahead (null when unknown).
  void _beginBufferingEpisode() {
    final now = DateTime.now();
    _bufferingStartedAt = now;
    _bufferingStartPosition = player.position;
    _bufferingStartAhead = _bufferedAhead(now);
  }

  /// What the player has loaded ahead of the playhead. For live HLS on
  /// AVPlayer, the timeline's estimate (see
  /// [HlsTimeline.bufferedAheadSeconds]); ExoPlayer and VOD report both
  /// positions in the same time base.
  Duration? _bufferedAhead(DateTime now) {
    if (!(ReconnectPolicy.silentStallPossible && _isLocalLiveHls)) {
      return player.bufferedPosition - player.position;
    }
    final seconds = _hlsTimeline.bufferedAheadSeconds(now);
    return seconds == null
        ? null
        : Duration(microseconds: (seconds * 1e6).round());
  }

  /// Whether the [repeats]-th repeat of an error is logged: the 1st, 10th,
  /// 100th and so on. Pure — unit tested directly.
  @visibleForTesting
  static bool isRepeatLogged(int repeats) {
    if (repeats < 1) return false;
    var n = repeats;
    while (n % 10 == 0) {
      n ~/= 10;
    }
    return n == 1;
  }

  /// Subscriber for `playbackEventStream.onError`. just_audio surfaces
  /// transient errors here without changing processingState (e.g. iOS HLS
  /// segment errors that the player recovers from). Dedup against the last
  /// emitted code/message so a sticky error doesn't spam the log.
  void _onPlayerStreamError(Object error, StackTrace stackTrace) {
    _log('playbackEventStream error: $error');
    int? code;
    String? msg;
    if (error is PlayerException) {
      code = error.code;
      msg = error.message;
    } else {
      msg = error.toString();
    }
    final shortMsg = msg == null
        ? ''
        : (msg.length > 120 ? msg.substring(0, 120) : msg);
    if (code == _lastPlayerErrorCode && msg == _lastPlayerErrorMessage) {
      _playerErrorRepeats++;
      // How sticky the error is, at a bounded cost.
      if (isRepeatLogged(_playerErrorRepeats)) {
        AnalyticsService.instance.logDebug('stream player error repeated', {
          'repeats': _playerErrorRepeats,
          'error_code': code,
          'error_message': shortMsg,
        });
      }
      return;
    }
    _lastPlayerErrorCode = code;
    _lastPlayerErrorMessage = msg;
    _playerErrorRepeats = 0;
    final lastInfo = currentStreamInfo.valueOrNull;
    _recordStreamEvent(
      StreamEventKind.playerError,
      'Player error${code != null ? ' code=$code' : ''}${shortMsg.isNotEmpty ? ': $shortMsg' : ''}',
    );
    final playerErrorProps = <String, Object?>{
      'station_slug':
          lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
      'station_id': currentStation.valueOrNull?.id,
      'stream_url': lastInfo?.url,
      'stream_type': lastInfo?.type,
      'stream_index': lastInfo?.attemptIndex,
      'total_streams': lastInfo?.totalStreams,
      'error_code': code,
      'error_message': msg,
      'error_runtime_type': error.runtimeType.toString(),
    };
    AnalyticsService.instance.logWarning('stream player error', playerErrorProps);
  }

  _log(String message) {
    developer.log("AppAudioHandler: $message");
  }

  /// [_log] that also lands in the app log at debug level: the commands and
  /// decisions a listener's log file should show (resume or reload, HLS
  /// starts and seeks, video handoffs). Not for anything that repeats every
  /// few seconds, which would push the history out of the file.
  void _trace(String message) {
    _log(message);
    AnalyticsService.instance.logDebug(message);
  }

  /// Compact error description for logs/PostHog (avoids dumping multi-line stack traces).
  static String _shortErr(Object e) {
    if (e is TimeoutException) return 'TimeoutException';
    if (e is PlayerException) return 'PlayerException(${e.code}): ${e.message ?? ''}';
    if (e is SocketException) return 'SocketException: ${e.message}';
    final s = e.toString();
    return s.length > 200 ? s.substring(0, 200) : s;
  }

  /// Classifies the last caught error into a [ConnectionError] with a reason.
  ConnectionError _classifyError(String stationName, Object? lastError) {
    ConnectionErrorReason reason;
    String? details;

    if (lastError is TimeoutException) {
      reason = ConnectionErrorReason.timeout;
    } else if (lastError is PlayerException) {
      final code = lastError.code;
      final msg = lastError.message ?? '';
      // iOS: -1009 = NSURLErrorNotConnectedToInternet (device truly offline)
      if (code == -1009) {
        reason = ConnectionErrorReason.network;
        details = msg;
      } else if (code == -1100 || (code >= 400 && code < 600)) {
        // -1100 = NSURLErrorFileDoesNotExist (HTTP 404 from server)
        // 4xx/5xx = HTTP server errors
        reason = ConnectionErrorReason.httpError;
        details = code == -1100 ? '404' : code.toString();
      } else {
        // -1004 = NSURLErrorCannotConnectToHost (server down, not user's internet)
        // ExoPlayer code 1 = TYPE_SOURCE (general source load failure)
        reason = ConnectionErrorReason.unknown;
        details = msg.isNotEmpty ? msg : null;
      }
    } else if (lastError is SocketException) {
      reason = ConnectionErrorReason.network;
      details = lastError.message;
    } else {
      reason = ConnectionErrorReason.unknown;
      details = lastError?.toString();
    }

    return ConnectionError(
      stationName: stationName,
      reason: reason,
      details: details,
    );
  }

  /// Cancels any in-flight play() operation by bumping the operation ID
  /// and completing the source load canceller.
  void _cancelInFlightPlay() {
    ++_playOperationId;
    _isConnecting = false;
    if (_sourceLoadCanceller != null && !_sourceLoadCanceller!.isCompleted) {
      _sourceLoadCanceller!.completeError('cancelled');
    }
  }

  /// Whether play()'s loop is trying one of [station]'s streams right now:
  /// not done, not cancelled and not waiting out a backoff.
  bool _isLoadingStation(Station? station) =>
      station != null &&
      _loadingStationId == station.id &&
      _retryBackoffWake == null &&
      _sourceLoadCanceller?.isCompleted == false;

  /// Tells the user (toast, CarPlay alert) and analytics that every stream
  /// of the station failed the pass that started at [passStartedAt].
  ///
  /// Only when the internet was up for the whole pass, confirmed first: a
  /// load on a network without internet only times out, and a pass that
  /// ran even partly offline says nothing about the station. The offline
  /// banner explains those, and the next pass decides. Dropped too when a
  /// newer play() call ([opId]) took over, or a retry connected, meanwhile.
  /// At most one error per play() call.
  Future<void> _surfaceConnectionError(
    Object? lastError, {
    required int opId,
    required DateTime passStartedAt,
    required bool passStartedOffline,
    required Map<String, Object?> properties,
  }) async {
    final network = NetworkService.instance;
    // Known to be offline: no check needed to stay quiet.
    if (passStartedOffline || network.isOffline.value) return;
    _errorPendingForOp = opId;
    try {
      await network.checkInternet();
    } finally {
      if (_errorPendingForOp == opId) _errorPendingForOp = -1;
    }
    if (opId != _playOperationId || !_isConnecting) return;
    final blamesStation = ReconnectPolicy.failedPassBlamesStation(
      startedAt: passStartedAt,
      startedOffline: passStartedOffline,
      offlineNow: network.isOffline.value,
      lastOfflineAt: _lastOfflineAt,
    );
    if (!blamesStation) return;
    _errorShownForOp = opId;
    final stationName = currentStation.valueOrNull?.title ?? '';
    final classified = _classifyError(stationName, lastError);
    connectionError.add(classified);
    PlaybackFailure.report(
      PlaybackFailureKind.allStreamsFailed,
      reason: classified.reason.name,
      properties: {...properties, 'details': classified.details},
    );
  }

  /// Whether a failed load got an HTTP error status (404, 503…), which is
  /// an answer from the station's server, not a network failure.
  static bool _isHttpStatusError(Object error) {
    if (error is! PlayerException) return false;
    final code = error.code;
    // -1100: NSURLErrorFileDoesNotExist, AVPlayer's HTTP 404.
    return code == -1100 || (code >= 400 && code < 600);
  }

  /// A growing buffer means audio data is arriving: proof the internet
  /// works, even when the reachability probes time out on a weak signal.
  void _reportAudioArriving(Duration bufferedPosition) {
    if (bufferedPosition > _lastBufferedPosition) {
      NetworkService.instance.reportRequestSuccess();
    }
    // A new source starts again from zero.
    _lastBufferedPosition = bufferedPosition;
  }

  /// Ends the play() loop's backoff between failed retry cycles now, so
  /// its next attempt runs as soon as the network is back.
  void _wakeRetryBackoff() {
    // The outage left the loop's next attempt on whichever stream was next
    // in line, often the fallback (no forward buffer). Start over at the
    // preferred one instead.
    if (_isConnecting) _restartPassAtPreferred = true;
    final wake = _retryBackoffWake;
    if (wake == null || wake.isCompleted) return;
    _trace('play: network back — retrying now instead of after the backoff');
    wake.complete();
  }

  // Android Auto media browsing support.
  // The system's built-in media browser calls this to build the browse tree.
  // No CarAppService needed — works like YouTube Music / Spotify.
  // Tabs, rows and their wording follow CarPlay's.
  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    _log("getChildren: $parentMediaId");
    return _androidAutoChildren(parentMediaId);
  }

  /// The rows of the Android Auto folder [parentMediaId].
  ///
  /// [getChildren] returns them and [subscribeToChildren] compares them, so
  /// a folder reloads exactly when the rows it shows change.
  List<MediaItem> _androidAutoChildren(String parentMediaId) {
    switch (parentMediaId) {
      case AudioService.recentRootId:
        return []; // Disabled: queue button on Now Playing screen is sufficient
      case AudioService.browsableRootId:
        return _androidAutoTabs();
      case AndroidAutoBrowseIds.favorites:
        // In the listener's order, as the phone's Favorite section.
        final bySlug = <Object?, MediaItem>{
          for (final item in stationsMediaItems.value)
            (item.extras?["station_slug"]): item,
        };
        return [
          for (final slug in stationDataService.favoriteStationSlugs.value)
            if (bySlug[slug] case final item?)
              _androidAutoRow(item,
                  id: AndroidAutoBrowseIds.favoriteItem(item.id)),
        ];
      case AndroidAutoBrowseIds.allStations:
        final favorites = stationDataService.favoriteStationSlugs.value.toSet();
        return [
          for (final item in stationsMediaItems.value)
            _androidAutoRow(item, starred: favorites, withSong: false),
        ];
      case AndroidAutoBrowseIds.categories:
        return _androidAutoCategories();
      default:
        if (AndroidAutoBrowseIds.groupSlugOf(parentMediaId) case final slug?) {
          return _androidAutoCategoryStations(slug);
        }
        return [];
    }
  }

  static const _androidResources =
      'android.resource://com.radiocrestin.radio_crestin/drawable';

  /// The root tabs: Favorite, Toate stațiile and, when a category
  /// qualifies, Categorii, as on CarPlay.
  List<MediaItem> _androidAutoTabs() => [
        MediaItem(
          id: AndroidAutoBrowseIds.favorites,
          title: CarStrings.favorites,
          artUri: Uri.parse('$_androidResources/ic_favorite'),
          playable: false,
          extras: const {
            'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1, // list
          },
        ),
        MediaItem(
          id: AndroidAutoBrowseIds.allStations,
          title: CarStrings.allStations,
          artUri: Uri.parse('$_androidResources/ic_radio'),
          playable: false,
          extras: const {
            'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1, // list
          },
        ),
        if (!stationDataService.carCategoryLayout().isEmpty)
          MediaItem(
            id: AndroidAutoBrowseIds.categories,
            title: CarStrings.categories,
            artUri: Uri.parse('$_androidResources/ic_category'),
            playable: false,
            extras: const {
              'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 1, // list
            },
          ),
      ];

  /// The categories, in the order a CarPlay driver meets them (see
  /// [CarCategoryLayout.all]), each with its CarPlay symbol as a white
  /// icon. Android Auto lists scroll, so the ones behind CarPlay's
  /// "Mai multe" need no level of their own.
  List<MediaItem> _androidAutoCategories() {
    return [
      for (final category in stationDataService.carCategoryLayout().all)
        MediaItem(
          id: AndroidAutoBrowseIds.group(category.slug),
          title: category.name,
          displayTitle: category.name,
          displaySubtitle: CarPlayService.stationCountText(
            category.stationIds.length,
            isRomanian: true,
          ),
          artUri: Uri.parse('$_androidResources/${category.androidIcon}'),
          playable: false,
          extras: const {
            'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1, // list
          },
        ),
    ];
  }

  /// The stations of the category [slug], in the car's order, with a star
  /// on the favorites. Their ids keep next/previous within the category.
  List<MediaItem> _androidAutoCategoryStations(String slug) {
    final category = stationDataService
        .carCategoryLayout()
        .all
        .where((c) => c.slug == slug)
        .firstOrNull;
    if (category == null) return const [];
    final favorites = stationDataService.favoriteStationSlugs.value.toSet();
    return [
      for (final item in stationsMediaItems.value)
        if (category.stationIds.contains(item.extras?['station_id']))
          _androidAutoRow(item,
              id: AndroidAutoBrowseIds.groupItem(slug, item.id),
              starred: favorites,
              withSong: false),
    ];
  }

  /// The station [item] of [stationsMediaItems] as a row of an Android Auto
  /// list, under [id] (by default its own media id).
  ///
  /// The stations of [starred] get a star, as CarPlay marks favorites in
  /// lists that mix them with other stations. Search and
  /// [playFromMediaId] read the plain titles of [stationsMediaItems].
  ///
  /// Without [withSong], the row leaves out the song playing on the
  /// station and keeps only what doesn't change while it plays ("Listă de
  /// redare" under a playlist station). Android Auto can't change a row in
  /// place: a new song reloads the whole list, which then jumps away from
  /// where the driver scrolled, and in a long list some station changes
  /// its song almost every minute.
  ///
  /// Of the extras, the row keeps Android Auto's own (`android.…`) and the
  /// station's id and slug, which [playMediaItem] reads. The stream list
  /// and the song fields, which nothing reads there, made every load of a
  /// long list a ~133 KB binder call; [playFromMediaId] finds the station
  /// with all of them in [stationsMediaItems].
  static MediaItem _androidAutoRow(
    MediaItem item, {
    String? id,
    Set<String> starred = const {},
    bool withSong = true,
  }) {
    final isStarred = starred.contains(item.extras?['station_slug']);
    final isPlaylist =
        item.extras?['station_type'] == StationMediaType.playlist.name;
    return item.copyWith(
      id: id ?? item.id,
      title: isStarred
          ? CarStrings.starredOnAndroidAuto(item.title)
          : item.title,
      // Android Auto shows the display title when there is one.
      displayTitle: isStarred
          ? CarStrings.starredOnAndroidAuto(item.displayTitle ?? item.title)
          : item.displayTitle,
      displaySubtitle: withSong
          ? item.displaySubtitle
          : CarPlayService.computeStationListSubtitle(
                displaySubtitle: '',
                isPlaylist: isPlaylist,
                isRomanian: true,
              ) ??
              '',
      artist: withSong ? item.artist : null,
      extras: {
        for (final MapEntry(:key, :value) in (item.extras ?? const {}).entries)
          if (key.startsWith('android.') ||
              key == 'station_id' ||
              key == 'station_slug')
            key: value,
      },
    );
  }

  /// What Android Auto draws of [rows], comparable by value (a [MediaItem]
  /// equals every other one with its id).
  ///
  /// Android draws a row's display texts when it has a display title, and
  /// otherwise its title, artist and album (`MediaMetadataCompat
  /// .getDescription`). The extras it reads, the content style and the
  /// sort key, are fixed for a row or follow its title.
  static List<Object?> _androidAutoSignature(List<MediaItem> rows) => [
        for (final row in rows)
          (
            row.id,
            row.playable,
            row.artUri,
            (row.displayTitle?.isNotEmpty ?? false)
                ? (row.displayTitle, row.displaySubtitle,
                    row.displayDescription)
                : (row.title, row.artist, row.album),
          ),
      ];

  /// The audio_service channel whose native side sets the media session's
  /// queue title. Its client channel only handles `configure`.
  static const _audioServiceChannel =
      MethodChannel('com.ryanheise.audio_service.handler.methods');

  /// Fetches song history for the current station and sets it as the
  /// MediaSession queue. Android Auto shows this as a "Up next"-style
  /// page accessible from the queue button on the Now Playing screen.
  Future<void> _updateSongHistoryQueue() async {
    // iOS ignores setQueue and nothing reads the queue there, so the
    // history fetch would be wasted on every station and song change.
    if (Platform.isIOS) return;
    final station = currentStation.valueOrNull;
    if (station == null) {
      queue.add([]);
      return;
    }
    // Set localized queue title FIRST (cached in native queueTitleOverride,
    // then re-applied each time setQueue is called). Sent every time: the
    // native side keeps it only once its service runs.
    const title = CarStrings.songHistory;
    queueTitle.add(title);
    // Fire-and-forget: cache the title on the native side before queue is set
    _audioServiceChannel.invokeMethod('setQueueTitle', {'title': title}).catchError((e) {
      print('RC_DEBUG: setQueueTitle error: $e');
    });

    try {
      print('RC_DEBUG: fetching history for ${station.slug}');
      // The default window (the last hour, no from/to) is one URL per
      // station, shared at the edge by every listener: cached 5 s near now
      // (backend B2), which is fine at this volume. The audible instant
      // trails now by at most a few minutes, so the window always covers it.
      final history = await SongHistoryService.fetchHistory(station.slug);
      print('RC_DEBUG: history result: ${history?.history.length ?? "null"} items');
      // The listener switched station while this was in flight: the newer
      // station's own update owns the queue.
      if (currentStation.valueOrNull?.id != station.id) return;
      if (history == null || history.history.isEmpty) {
        queue.add([]);
        return;
      }
      final stationThumbUrl = station.thumbnailUrl;
      // Only songs the listener already heard: on time-shifted HLS the
      // newest rows are still ahead of the audible instant.
      final pastSongs = SongHistoryService.playedBefore(history.history,
          stationDataService.playedCutoffFor(station.id));
      final items = pastSongs
          .take(30)
          .map((item) {
            final time = item.dateTime.toLocal();
            final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
            final thumbUrl = item.songThumbnailUrl ?? stationThumbUrl;
            return MediaItem(
              id: 'history_${station.slug}_${item.timestamp}',
              title: item.displaySongName ?? 'Necunoscut',
              artist: item.artistName != null
                  ? '$timeStr - ${item.displayArtistName}'
                  : timeStr,
              artUri: thumbUrl != null ? Uri.parse(thumbUrl) : null,
            );
          })
          .toList();
      print('RC_DEBUG: setting queue with ${items.length} items');
      queue.add(items);
    } catch (e) {
      print('RC_DEBUG: _updateSongHistoryQueue error: $e');
    }
  }

  // PlaybackStateCompat.ERROR_CODE_UNKNOWN_ERROR: none of the media
  // session's error codes is about the internet.
  static const _errorCodeUnknown = 0;

  static const _offlineErrorMessage = 'Verifică conexiunea la internet.';

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) {
    _log("subscribeToChildren: $parentMediaId");
    switch (parentMediaId) {
      case AudioService.recentRootId:
        final stream = _recentSubject.map((_) => <String, dynamic>{});
        return _recentSubject.hasValue
            ? stream.shareValueSeeded(<String, dynamic>{})
            : stream.shareValue();
      default:
        return _childrenChanges(parentMediaId);
    }
  }

  /// Asks Android Auto to reload the folder [parentMediaId] when the rows it
  /// shows change, and only then.
  ///
  /// A reload rebuilds the list on the car screen, which can move it away
  /// from where the driver scrolled (a tap then starts another station), so
  /// a poll that changes nothing on the screen, such as listener counts,
  /// reloads nothing. The songs under the favorites stay live, as on
  /// CarPlay; Toate stațiile and the categories show none (see
  /// [_androidAutoRow]), and the root tabs reload only when Categorii comes
  /// or goes.
  ///
  /// audio_service reloads the folder on every event. The sources are
  /// [BehaviorSubject]s that replay their values on listen, so the first
  /// signature is the folder's first load and only later changes count.
  /// The seed reloads every folder once after its first load.
  ValueStream<Map<String, dynamic>> _childrenChanges(String parentMediaId) =>
      Rx.merge<Object?>([
        // The station list (songs, hidden stations), the favorites (their
        // order and stars) and the categories.
        stationsMediaItems,
        stationDataService.favoriteStationSlugs,
        stationDataService.stationGroups,
      ])
          .map((_) =>
              _androidAutoSignature(_androidAutoChildren(parentMediaId)))
          .distinct(listEquals)
          .skip(1)
          .map((_) => <String, dynamic>{})
          .shareValueSeeded(<String, dynamic>{});

  final AudioPlayer player;

  // ignore: close_sinks
  final BehaviorSubject<List<MediaItem>> _recentSubject = BehaviorSubject.seeded(<MediaItem>[]);
  static const LAST_PLAYED_MEDIA_ITEM = "last_played_media_item";

  SharedPreferences get _prefs => GetIt.instance<SharedPreferences>();

  // Per-URL failure memory + retry pacing for the play() retry loop and
  // every reconnect trigger. See [StreamFailover] for the policy.
  final StreamFailover _failover = StreamFailover();

  final PlayCountTracker _playCountTracker = PlayCountTracker(
    onCounted: (slug) =>
        GetIt.instance<PlayCountService>().incrementPlayCount(slug),
  );
  StreamSubscription<bool>? _playCountSub;

  AppAudioHandler({required this.graphqlClient, required this.player}) {
    stationDataService.getPlayingStationId =
        () => currentStation.valueOrNull?.id;
    stationDataService.isTimeShiftedHlsActive = () => _isLocalLiveHls;
    stationDataService.isLiveStreamActive =
        () => _loadedStreamType != null && _loadedStreamType != 'HLS';
    stationDataService.getAudibleInstant = _audibleInstant;
    // TV shows live metadata (not the HLS-buffered song) — see
    // [StationDataService.preferLiveMetadata].
    stationDataService.preferLiveMetadata = TvPlatform.isAndroidTV;
    _initPlayer();
    _initUpdateCurrentStationMetadata();
    _initPlayCounting();
  }

  /// Feeds the play counter whether audio is going (locally, cast or
  /// video), so a station counts only once it has really been heard.
  void _initPlayCounting() {
    _playCountSub = playbackState
        .map((s) =>
            s.playing && s.processingState == AudioProcessingState.ready)
        .distinct()
        .listen(_playCountTracker.playingChanged);
  }

  // Audio Player
  Future<void> _initPlayer() async {
    _trace("initPlayer");

    // Propagate all events from the audio player to AudioService clients.
    // Errors raised on this stream (PlayerException etc.) are surfaced through
    // onError — these can fire without changing processingState (e.g., iOS
    // AVAudio session resets, transient HLS segment errors) and without them
    // a brief glitch leaves no trace in the diagnostic log.
    player.playbackEventStream.listen(
      (event) {
        _endAwaitingAudioStart(event);
        _broadcastState(event);
        _onPlayerEventForTimeline(event);
        _reportAudioArriving(event.bufferedPosition);
        _noteLoadAfterOutage(event.bufferedPosition);
      },
      onError: _onPlayerStreamError,
    );

    // Ensure play/pause state changes are broadcast immediately.
    // playbackEventStream fires on position/buffer changes but may not fire
    // promptly on play()/pause() transitions. playingStream fires exactly
    // when the playing state flips, guaranteeing CarPlay/Android Auto sync.
    player.playingStream.listen((playing) {
      _stoppedPlayingAt =
          playing ? null : (_stoppedPlayingAt ?? DateTime.now());
      _broadcastState(player.playbackEvent);
      _syncLiveHlsWatchdog();
      _onPlayerEventForTimeline(player.playbackEvent);
    });

    // Fast-start measurement: catch the first position advance while playing.
    // Debug-only; the listener is a cheap early-return once the measure is done.
    if (kDebugMode) {
      player.positionStream.listen((_) => _maybeCompleteFastStartMeasure());
    }

    // ICY tag listener (direct/MP3 streams). just_audio surfaces SHOUTcast
    // ICY metadata (`StreamTitle`) on this stream — when the title flips,
    // the audio is announcing a new song. The live list is re-fetched until
    // the new row shows up, so the station's now-playing line catches up
    // immediately. HLS streams use the playlist's song boundaries
    // (`_queueSongBoundaries`) instead.
    player.icyMetadataStream.listen((icy) {
      final title = icy?.info?.title;
      if (title == null || title.isEmpty) return;
      if (title == _lastIcyTitle) return;
      final firstOfStream = _lastIcyTitle == null;
      _lastIcyTitle = title;
      if (firstOfStream) {
        // The song already playing when the stream started, not a change:
        // its row may have started minutes ago, so a follow-up waiting for
        // a fresh row would only repeat the live fetch for 40 s.
        _trace("icy metadata: first title $title — refreshing live");
        unawaited(
            stationDataService.enqueueSync(SyncReason.liveMetadataChanged));
        return;
      }
      _trace("icy metadata change: $title — refreshing");
      unawaited(stationDataService.refreshMetadataNow());
    });

    // Handle stream lifecycle events:
    // - completed: HLS reconnect, MP3 stop
    // - idle while playing: stream dropped (e.g., network lost in background)
    // Guard: skip reconnection while loading a new source (_isConnecting),
    // as the idle/completed event is from the previous source being stopped.
    player.processingStateStream.listen((state) {
      // Record any buffering exit before per-state handling — captures every
      // brief rebuffer ≥250ms regardless of how the buffering ended.
      if (_bufferingStartedAt != null && state != ProcessingState.buffering) {
        _recordBufferingExit(state);
      }

      // Playlist mode: just_audio plays a single VOD item. `completed` means
      // end-of-item → advance (the station-stream reconnect / reload logic
      // below is wrong here because it re-issues play() over station_streams).
      if (_playlistMode) {
        if (state == ProcessingState.completed) {
          _bufferingStallTimer?.cancel();
          if (_isConnecting) return;
          _trace('processingStateStream: playlist item completed → advance');
          onPlaylistItemCompleted?.call();
        } else if (state == ProcessingState.buffering && player.playing) {
          if (_bufferingStartedAt == null) {
            _beginBufferingEpisode();
            _scheduleSilenceKeepAlive();
          }
        } else if (state == ProcessingState.ready) {
          _bufferingStallTimer?.cancel();
          _stopSilenceKeepAlive();
        } else {
          _stopSilenceKeepAlive();
        }
        return;
      }

      if (state == ProcessingState.completed) {
        _bufferingStallTimer?.cancel();
        if (_isConnecting) return;
        final isHls = _loadedStreamType == 'HLS';
        if (isHls) {
          // AVPlayer occasionally reports `completed` for live HLS streams
          // during PDT-decoder confusion in the first few seconds after
          // load. Without a debounce we re-issue play() and create a 3s
          // reload loop visible to the user as repeated startup hiccups
          // (5x "Attempt → Loaded → Rebuffer" within 10s, all with the
          // textbook 132009ms buf-ahead). Suppress reload if we just
          // loaded successfully.
          final lastLoad = _lastSuccessfulLoadAt;
          if (lastLoad != null &&
              DateTime.now().difference(lastLoad) < _terminalStateReloadDebounce) {
            _trace("processingStateStream: HLS completed within debounce window — ignoring (likely PDT confusion, not real EOS)");
            _recordStreamEvent(
              StreamEventKind.hlsCompleted,
              'HLS completed (debounced — recently loaded)',
            );
            return;
          }
          _log("processingStateStream: HLS stream completed unexpectedly, reconnecting");
          final lastInfo = currentStreamInfo.valueOrNull;
          _recordStreamEvent(
            StreamEventKind.hlsCompleted,
            'HLS completed unexpectedly — reconnecting',
          );
          AnalyticsService.instance.logWarning('stream unexpected completion', {
            'station_slug': lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
            'station_id': currentStation.valueOrNull?.id,
            'stream_url': lastInfo?.url,
            'stream_type': lastInfo?.type ?? 'HLS',
            'stream_index': lastInfo?.attemptIndex,
            'total_streams': lastInfo?.totalStreams,
            'ms_since_loaded': lastInfo == null
                ? null
                : DateTime.now().difference(lastInfo.loadedAt).inMilliseconds,
          });
          // The completed URL is suspect — remember it so the reconnect
          // starts at the next stream instead of re-looping on it.
          if (_loadedStreamUrl != null) {
            _recordStreamFailure(_loadedStreamUrl!, DateTime.now());
          }
          _loadedStreamUrl = null;
          _loadedStreamType = null;
          play();
        } else {
          _log("processingStateStream: non-HLS stream completed unexpectedly");
          final lastInfo = currentStreamInfo.valueOrNull;
          _recordStreamEvent(
            StreamEventKind.nonHlsCompleted,
            'Non-HLS stream completed — stopping',
          );
          final completionProps = <String, Object?>{
            'station_slug': lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
            'station_id': currentStation.valueOrNull?.id,
            'stream_url': lastInfo?.url,
            'stream_type': lastInfo?.type,
            'stream_index': lastInfo?.attemptIndex,
            'total_streams': lastInfo?.totalStreams,
            'ms_since_loaded': lastInfo == null
                ? null
                : DateTime.now().difference(lastInfo.loadedAt).inMilliseconds,
          };
          AnalyticsService.instance
              .logWarning('stream unexpected completion', completionProps);
          PlaybackFailure.report(
            PlaybackFailureKind.streamEnded,
            properties: completionProps,
          );
          final stationName = currentStation.valueOrNull?.title ?? '';
          connectionError.add(ConnectionError(
            stationName: stationName,
            reason: ConnectionErrorReason.unknown,
          ));
          _stopDueToError();
        }
      } else if (state == ProcessingState.idle && player.playing) {
        _bufferingStallTimer?.cancel();
        if (_isConnecting) return;
        // Same debounce as the `completed` branch — AVPlayer briefly
        // dipping into idle-while-playing within a few seconds of a
        // successful load is a PDT/decoder edge case, not a real
        // network drop. Don't re-issue play() while the source is
        // still considered healthy.
        final lastLoad = _lastSuccessfulLoadAt;
        if (lastLoad != null &&
            DateTime.now().difference(lastLoad) < _terminalStateReloadDebounce) {
          _trace("processingStateStream: idle-while-playing within debounce window — ignoring");
          _recordStreamEvent(
            StreamEventKind.lostIdle,
            'Stream idle-while-playing (debounced — recently loaded)',
          );
          return;
        }
        _log("processingStateStream: stream lost (idle while playing), reconnecting");
        final lastInfo = currentStreamInfo.valueOrNull;
        _recordStreamEvent(
          StreamEventKind.lostIdle,
          'Stream lost (idle while playing) — reconnecting',
        );
        AnalyticsService.instance.logWarning('stream lost idle', {
          'station_slug': lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
          'station_id': currentStation.valueOrNull?.id,
          'stream_url': lastInfo?.url,
          'stream_type': lastInfo?.type,
          'stream_index': lastInfo?.attemptIndex,
          'total_streams': lastInfo?.totalStreams,
          'ms_since_loaded': lastInfo == null
              ? null
              : DateTime.now().difference(lastInfo.loadedAt).inMilliseconds,
        });
        // The lost URL is suspect — start the reconnect at the next stream.
        if (_loadedStreamUrl != null) {
          _recordStreamFailure(_loadedStreamUrl!, DateTime.now());
        }
        _loadedStreamUrl = null;
        _loadedStreamType = null;
        play();
      } else if (state == ProcessingState.buffering && player.playing && !_isConnecting) {
        // Capture the moment buffering started, with position + buffered
        // position. The gap (buffered - position) at start tells us whether
        // the network drained ahead of time (small gap = network slow) or
        // the decoder stalled on a buffered segment (large gap = server
        // segment problem). This is the highest-signal data for short
        // audible glitches.
        // Capture position/buffered only on first entry per buffering episode,
        // mirroring _bufferingStartedAt — otherwise a re-emission of the same
        // state would silently advance the snapshot while the timer keeps
        // counting from the original moment, skewing buf-ahead-at-start.
        if (_bufferingStartedAt == null) {
          _beginBufferingEpisode();
          _scheduleSilenceKeepAlive();
        }
        // Stall timer: if buffering doesn't resolve, kick a fresh play()
        // instead of giving up. play() cycles the station's stream URLs
        // (skipping recently-failed ones) and surfaces a connectionError
        // only after a full cycle fails. Goal: the stream auto-recovers
        // without the user noticing — never stop on a transient blip.
        _bufferingStallTimer?.cancel();
        _bufferingStallTimer = Timer(_bufferingStallTimeout, () {
          if (player.processingState == ProcessingState.buffering && player.playing) {
            _log("processingStateStream: buffering stalled for ${_bufferingStallTimeout.inSeconds}s, reattempting play()");
            final lastInfo = currentStreamInfo.valueOrNull;
            _recordStreamEvent(
              StreamEventKind.bufferingStall,
              'Buffering stalled ${_bufferingStallTimeout.inSeconds}s — reattempting',
            );
            final stallProps = <String, Object?>{
              'station_slug': lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
              'station_id': currentStation.valueOrNull?.id,
              'stream_url': lastInfo?.url,
              'stream_type': lastInfo?.type,
              'stream_index': lastInfo?.attemptIndex,
              'total_streams': lastInfo?.totalStreams,
              'stall_seconds': _bufferingStallTimeout.inSeconds,
              'action': 'reattempt',
            };
            AnalyticsService.instance
                .logWarning('stream buffering stall', stallProps);
            _recordStreamTrouble('buffering_stall');
            // A stalled stream counts as a failed one: remember it so the
            // reconnect starts at the next stream if it stalls repeatedly.
            if (_loadedStreamUrl != null) {
              _recordStreamFailure(_loadedStreamUrl!, DateTime.now());
            }
            // Force play() to re-issue setAudioSource (rather than skip
            // because the URL is "already loaded").
            _loadedStreamUrl = null;
            _loadedStreamType = null;
            play();
          }
        });
      } else if (state == ProcessingState.ready) {
        _bufferingStallTimer?.cancel();
        // A loaded stream is ready before play() starts it: the keeper
        // stays on until then (see the end of play()).
        if (!_isConnecting) _stopSilenceKeepAlive();
      } else if (!_isReconnectingOnIntent) {
        // Loading and idle while play() reconnects keep the keeper on: it
        // is what keeps the app running until the network is back.
        _stopSilenceKeepAlive();
      }
    });

    await player.setLoopMode(LoopMode.off);
    _attachAudioSessionHandlers();
  }

  /// Subscribes to AudioSession interruption + becomingNoisy events: pauses
  /// and resumes for them, and writes them to the diagnostic ring buffer.
  Future<void> _attachAudioSessionHandlers() async {
    try {
      final session = await AudioSession.instance;
      session.interruptionEventStream.listen((event) {
        final phase = event.begin ? 'begin' : 'end';
        final type = event.type.name;
        _recordStreamEvent(
          StreamEventKind.audioInterruption,
          'AudioSession interruption $phase ($type)',
        );
        AnalyticsService.instance.log('audio session interruption', {
          'phase': phase,
          'type': type,
          'player_processing_state': player.processingState.name,
          'player_playing': player.playing,
          'position_ms': player.position.inMilliseconds,
          'buffered_ms': player.bufferedPosition.inMilliseconds,
        });
        _onAudioInterruption(event);
      });
      session.becomingNoisyEventStream.listen((_) {
        _recordStreamEvent(
          StreamEventKind.audioInterruption,
          'AudioSession becoming noisy (route disconnect)',
        );
        AnalyticsService.instance.log('audio session becoming noisy');
        _pauseForSystemEvent('becoming_noisy');
      });
    } catch (e) {
      _log('audio session handlers setup failed: $e');
      // Calls and unplugged headphones will then go unhandled.
      AnalyticsService.instance
          .logWarning('audio session handlers failed', {'error': '$e'});
    }
  }

  /// Pauses for an interruption (a call, Siri, another app's audio) and
  /// resumes when it ends, if the system allows it.
  ///
  /// The same rules as just_audio's own handling, which the player has
  /// turned off, but through [pause] and [play]: just_audio paused and
  /// resumed the player behind the handler, so the handler still counted
  /// the stream as playing, and the resume reused a paused live stream
  /// that may have gone stale instead of reloading it.
  void _onAudioInterruption(AudioInterruptionEvent event) {
    if (!event.begin) {
      // `pause` ends an interruption that allows a resume (iOS
      // shouldResume, Android transient focus loss).
      final resume = _resumeAfterInterruption &&
          event.type == AudioInterruptionType.pause;
      _resumeAfterInterruption = false;
      if (resume) {
        _log('interruption ended, resuming');
        AnalyticsService.instance
            .log('system resume', {'reason': 'interruption_ended'});
        _isInterruptionResume = true;
        unawaited(play());
      }
      return;
    }
    switch (event.type) {
      case AudioInterruptionType.duck:
        // Android ducks media playback by itself.
        return;
      case AudioInterruptionType.unknown when Platform.isAndroid:
        // Permanent focus loss (another app took the audio): no end
        // follows. Not for YouTube items: the WebView's own focus request
        // would pause the item that just started.
        if (!_playlistYoutubeActive) _pauseForSystemEvent('focus_loss');
      case AudioInterruptionType.pause:
      case AudioInterruptionType.unknown:
        // Every iOS begin is `unknown`; its end says whether to resume.
        // Only the just_audio player, as before: video, YouTube items and
        // Cast are left to their own handling.
        if (!player.playing) return;
        // Set after pause(), which clears it.
        if (_pauseForSystemEvent('interruption')) {
          _resumeAfterInterruption = true;
        }
    }
  }

  /// Pauses for a system event (route disconnect, focus loss, interruption)
  /// as a user pause would. Returns whether it paused.
  ///
  /// The play intent must be cleared: otherwise the next foreground or
  /// network restore reconnects and plays through the speaker, even when
  /// no resume follows. pause() also arms the 60 s disconnect (stops the
  /// playlist poll) and ends the listening session.
  bool _pauseForSystemEvent(String reason) {
    if (isCasting || !(_hasBeenPlayed || player.playing)) return false;
    _log('system pause ($reason)');
    AnalyticsService.instance.log('system pause', {'reason': reason});
    unawaited(pause());
    return true;
  }

  /// Test seam: handles [event] as if the audio session had emitted it
  /// (the faked platform channels have no audio session).
  @visibleForTesting
  void debugOnAudioInterruption(AudioInterruptionEvent event) =>
      _onAudioInterruption(event);

  /// Public hook called by HomePage's didChangeAppLifecycleState. Logs every
  /// transition to the ring buffer so a screen-lock-triggered hiccup is
  /// visually adjacent to the lifecycle change in the user's diagnostic copy.
  void recordLifecycleTransition(String state) {
    _recordStreamEvent(
      StreamEventKind.lifecycle,
      'App lifecycle: $state',
    );
    AnalyticsService.instance.logDebug('app lifecycle', {'state': state});
  }

  @override
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]) async {
    _trace('setRating($rating)');
    final station = currentStation.value;
    if (station == null) return;
    await setStationIsFavorite(station, rating.hasHeart());
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    _trace('customAction($name, $extras)');
    switch (name) {
      case 'toggleFavorite':
        final station = currentStation.value;
        if (station == null) return;
        final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
        await setStationIsFavorite(station, !isFav);
        // Re-broadcast so notification icon updates immediately
        _broadcastState(player.playbackEvent);
        break;
      case 'likeSong':
        final likeStation = currentStation.value;
        if (likeStation == null) return;
        final currentLike = _songLikeService.getLikeStatus(likeStation.songId);
        // Toggle: if already liked, reset to neutral; otherwise set to liked
        final newStatus = currentLike == 1 ? 0 : 1;
        await _songLikeService.setLikeStatus(
          stationId: likeStation.id,
          songId: likeStation.songId,
          likeStatus: newStatus,
          thumbnailUrl: likeStation.thumbnailUrl,
          songTitle: likeStation.songTitle,
          songArtist: likeStation.songArtist,
        );
        _broadcastState(player.playbackEvent);
        if (newStatus == 1) {
          _countReviewAction();
          final info = _buildSongInfo(likeStation);
          ReviewService.submitReview(
            stationId: likeStation.id,
            stars: 5,
            message: 'I like: $info',
            userIdentifier: globals.deviceId,
            songId: likeStation.songId,
          );
        } else {
          // Removing like — delete the review on the backend
          ReviewService.deleteReview(
            stationId: likeStation.id,
            songId: likeStation.songId,
          );
        }
        break;
      case 'dislikeSong':
        final dislikeStation = currentStation.value;
        if (dislikeStation == null) return;
        final currentDislike = _songLikeService.getLikeStatus(dislikeStation.songId);
        // Toggle: if already disliked, reset to neutral; otherwise set to disliked
        final newDislikeStatus = currentDislike == -1 ? 0 : -1;
        await _songLikeService.setLikeStatus(
          stationId: dislikeStation.id,
          songId: dislikeStation.songId,
          likeStatus: newDislikeStatus,
          thumbnailUrl: dislikeStation.thumbnailUrl,
          songTitle: dislikeStation.songTitle,
          songArtist: dislikeStation.songArtist,
        );
        _broadcastState(player.playbackEvent);
        if (newDislikeStatus == -1) {
          final info = _buildSongInfo(dislikeStation);
          ReviewService.submitReview(
            stationId: dislikeStation.id,
            stars: 1,
            message: "I don't like: $info",
            userIdentifier: globals.deviceId,
            songId: dislikeStation.songId,
          );
        } else {
          // Removing dislike — delete the review on the backend
          ReviewService.deleteReview(
            stationId: dislikeStation.id,
            songId: dislikeStation.songId,
          );
        }
        break;
      case 'showSongHistory':
        final station = currentStation.value;
        if (station == null) return;
        // Refresh the queue with latest song history
        await _updateSongHistoryQueue();
        // Store pending action so the app shows the modal when foregrounded
        _prefs.setString('pending_song_history', station.slug);
        // Bring the app to the foreground
        try {
          const channel = MethodChannel('com.radiocrestin.app');
          await channel.invokeMethod('bringToForeground');
        } catch (_) {
          // Ignore — app may already be in foreground or iOS doesn't need this
        }
        // Also notify the phone UI if already in foreground
        customEvent.add({
          'action': 'showSongHistory',
          'stationId': station.id,
          'stationSlug': station.slug,
          'stationThumbnailUrl': station.thumbnailUrl,
        });
        break;
    }
    return super.customAction(name, extras);
  }

  Future<void> selectStation(Station picked) async {
    // Its song as of now, not as of the list's last publish: a song can
    // reach the listeners between two syncs.
    final station = stationDataService.shownNow(picked);
    _log('selectStation($station)');
    print('RC_DEBUG: selectStation ${station.slug}');

    final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);

    // Always use station thumbnail (cached) to save bandwidth.
    // Song metadata (title/artist) is still shown from the station data.
    final stationItem = _buildStationMediaItem(station);
    _lastEmittedSongId = station.songId;
    mediaItem.add(stationItem.copyWith(rating: Rating.newHeartRating(isFav)));
    _ensureStationArtCached(station);
    currentStation.add(station);

    // Fire-and-forget: don't block the tap path with disk I/O
    setLastPlayedStation(station);
    // Populate queue with song history for Android Auto queue page
    _updateSongHistoryQueue();
  }

  /// The `artist` and `album` lines under the station name on the system
  /// Now Playing screens.
  ///
  /// CarPlay shows both, one under the other, so while it is connected the
  /// song and its artist get a line each instead of the station name
  /// repeating under the song. Elsewhere `artist` keeps the song and its
  /// artist together, for screens that show a single line under the title.
  static ({String? artist, String? album}) nowPlayingLines(
    Station station, {
    required bool onCarPlay,
  }) {
    if (!onCarPlay) {
      return (artist: station.artist, album: station.rawStationData.title);
    }
    return (
      artist: station.songTitle.isEmpty ? null : station.songTitle,
      album: station.songArtist.isEmpty ? null : station.songArtist,
    );
  }

  /// Builds a MediaItem with the station thumbnail URL and song metadata.
  /// Always uses HTTPS URLs for artUri (not file:// cached paths) because
  /// Android Auto's system player runs in a separate process and can't
  /// access our app's internal storage.
  MediaItem _buildStationMediaItem(Station station) {
    final thumbnailUrl = station.rawStationData.thumbnail_url;
    final Uri stationArtUri = (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
        ? Uri.parse(thumbnailUrl)
        : Uri.parse(CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL);
    final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
    final lines = nowPlayingLines(
      station,
      onCarPlay: Platform.isIOS && isCarConnected,
    );
    return MediaItem(
      id: Utils.getStationStreamUrls(station.rawStationData).firstOrNull ?? "",
      title: station.rawStationData.title,
      album: lines.album,
      displayTitle: station.displayTitle,
      displaySubtitle: station.displaySubtitle,
      artist: lines.artist,
      duration: null,
      artUri: stationArtUri,
      isLive: true,
      rating: Rating.newHeartRating(isFav),
      extras: {
        "station_id": station.rawStationData.id,
        "station_slug": station.rawStationData.slug,
        "station_title": station.rawStationData.title,
        "song_id": station.songId,
        "song_title": station.songTitle,
        "song_artist": station.artist,
        "total_listeners": station.rawStationData.total_listeners,
        "station_is_up": station.isUp,
        "station_thumbnail_url": station.rawStationData.thumbnail_url,
        "station_streams": Utils.getStationStreamObjects(station.rawStationData),
      },
    );
  }

  /// Pre-caches the station thumbnail to disk for the in-app UI.
  /// Does NOT re-emit mediaItem with file:// URIs — the MediaSession
  /// artUri stays as HTTPS so Android Auto's system player (which runs
  /// in a separate process) can download it directly.
  void _ensureStationArtCached(Station station) {
    final stationThumbnailUrl = station.rawStationData.thumbnail_url;
    if (stationThumbnailUrl == null || stationThumbnailUrl.isEmpty) return;
    // Just trigger the download for in-app disk cache — don't replace artUri
    ImageCacheService.instance.getOrDownload(stationThumbnailUrl);
  }

  /// In unstable connection mode, cache song thumbnails permanently to disk.
  /// This ensures thumbnails are available even on poor connections.
  void _ensureSongThumbnailCachedPermanently(Station station) {
    final songThumbnailUrl = station.rawStationData.now_playing?.song?.thumbnail_url;
    if (songThumbnailUrl == null || songThumbnailUrl.isEmpty) return;
    // Just trigger download — ImageCacheService stores on disk permanently
    ImageCacheService.instance.getOrDownload(songThumbnailUrl);
  }

  /// Whether a switch between two audio stations keeps the native player:
  /// it pauses the old station, and the new station's load replaces it.
  ///
  /// just_audio's stop() disposes the native player, and the next load
  /// builds a new one. On Android, ExoPlayer's release holds the main
  /// thread, which is also the UI thread, for 23–36 ms on every switch,
  /// before the new station shows. A load on the same ExoPlayer first
  /// stops the old source without waiting, so it goes silent at once.
  /// iOS is unchanged: its silence keeper and hold proxy were built
  /// around the stop. Retries still load on a fresh player.
  @visibleForTesting
  static bool switchKeepsNativePlayer = Platform.isAndroid;

  /// Whether the switch to [station] loads its stream right away over the
  /// old one (see [switchKeepsNativePlayer]). A playlist, a TV station
  /// (video) or a Cast session plays elsewhere: the player stops, as
  /// before.
  bool _switchReplacesSource(Station station) =>
      switchKeepsNativePlayer &&
      !station.isPlaylist &&
      !station.isTv &&
      !isCasting;

  Future<void> playStation(
    Station station, {
    bool? fromFavorites,
    String? fromGroup,
  }) async {
    _log('playStation(${station.slug}, fromFavorites=$fromFavorites, '
        'fromGroup=$fromGroup)');
    AnalyticsService.instance.logDebug('station switch', {
      'to_station_slug': station.slug,
      'from_station_slug': currentStation.valueOrNull?.slug,
      'station_type': station.stationType.name,
      'from_favorites': fromFavorites,
      'from_group': fromGroup,
    });
    _beginFastStartMeasure(station);
    // Before the early returns: picking the station already loading is
    // still a request the listener waits on.
    _onPlayRequested();
    _hasBeenPlayed = true;
    _resumeAfterInterruption = false;

    // Navigation context for next/previous: true when picked from a favorites
    // list, false from any other list, search or link, with [fromGroup] the
    // slug of the car category it was picked from. Null (skip, resume of
    // the last station) keeps the current context.
    assert(fromGroup == null || fromFavorites == false);
    if (fromFavorites != null) {
      stationDataService.startedFromFavorites = fromFavorites;
      stationDataService.startedFromGroup = fromGroup;
    }

    // Counted for "Most played" and the recommendations only once heard.
    _playCountTracker.stationPicked(station.slug);

    // Avoid stop-restart if already playing this exact playlist station.
    if (station.isPlaylist &&
        _playlistMode &&
        _playlistController.activeStation?.id == station.id) {
      _trace('playStation: playlist ${station.slug} already active, skipping');
      return;
    }

    // Avoid stop-restart if already playing/loading this exact station
    // (audio/TV path only — playlist is handled above).
    if (!station.isPlaylist &&
        currentStation.valueOrNull?.id == station.id &&
        isPlayingOrConnecting) {
      _trace('playStation: already playing/loading station ${station.slug}, skipping');
      return;
    }

    // A tap, next/previous, autoplay or car pick: one review action each.
    _countReviewAction();

    // Cancel any in-flight play() from a previous playStation() call
    _cancelInFlightPlay();
    // A newer switch, or a pause/stop, can land during any await below: a
    // second stop() returns at once, so a later tap could otherwise be
    // overtaken by this one, and a pause would be ignored.
    final switchId = ++_stationSwitchId;

    // New station selection — forget any prior video→audio fallback so this
    // station gets a fresh video attempt and the chip starts hidden.
    resetVideoFallback();

    // Tearing down the previous station: leave any active playlist and stop
    // video mode so the new station starts from a clean slate.
    if (_playlistMode && !station.isPlaylist) {
      await _playlistController.stop();
      if (switchId != _stationSwitchId) return;
    }
    if (_videoMode) {
      await _exitVideoMode(stopVideo: true);
      if (switchId != _stationSwitchId) return;
    }

    // Enter "connecting" state BEFORE stopping (or pausing, see
    // switchKeepsNativePlayer) the player so that _broadcastState emits
    // processingState=loading (not ready).
    // Without this, player.stop() → idle → mapped to ready (a paused player
    // stays ready) → AnimatedPlayButton treats it as settled state and
    // clears the optimistic play intent, causing the pause button to stop
    // working during the transition.
    _isConnecting = true;
    _broadcastState(player.playbackEvent);
    // The silence play() keeps until the new station plays (see there)
    // starts before the previous station stops: in the gap without audio,
    // iOS would flash the play button.
    if (Platform.isIOS) unawaited(_startSilenceKeepAlive());

    // Stop and clean up the previous station before starting the new one.
    // Aligned playback ends only after the new station is selected: ending
    // it here would publish the old station's live (not yet heard) song
    // while it is still current, and the stations listener would push it
    // to the lock screen, CarPlay and the Android Auto queue.
    _disconnectTimer?.cancel();
    _stopHlsPlaylistRefresh(endAlignedPlayback: false);
    if (player.playing || player.processingState != ProcessingState.idle) {
      if (_switchReplacesSource(station)) {
        // Forgotten before the await: a pause landing in it would otherwise
        // leave the old source to a fast resume, its timeline reset above.
        // A rebuffer the switch cuts short is logged as the stop's idle
        // logged it.
        _loadedStreamUrl = null;
        _loadedStreamType = null;
        _recordBufferingExit(ProcessingState.idle);
        await player.pause();
      } else {
        await player.stop();
      }
      if (switchId != _stationSwitchId) return;
    }
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    _bufferingStartedAt = null;
    _stopLiveHlsWatchdog();
    _lastPlayerErrorCode = null;
    _lastPlayerErrorMessage = null;
    // Reset the ICY-title dedupe so the next stream's first title fires a refresh.
    _lastIcyTitle = null;
    // Clear stream context so listening_started for the new station and the
    // Settings diagnostic don't carry the previous station's URL/type/index
    // until play() loads the new source.
    currentStreamInfo.add(null);
    AnalyticsService.instance.setCurrentStream(url: null, type: null, index: null, total: null);

    await selectStation(station);
    // The previous station is no longer current, so clearing its overlay
    // only shows its live song in the list.
    stationDataService.onAlignedPlaybackEnded();
    if (switchId != _stationSwitchId) return;

    // Tell the sync engine the user just picked this station — drives a
    // live diff so the playing-station UI sees the freshest now-playing
    // and listener counts before audio starts.
    unawaited(stationDataService.onStationPlayed());

    // When casting, send directly to Chromecast — don't start local audio.
    if (isCasting) {
      _trace('playStation: casting active, sending to Cast');
      _isConnecting = false;
      // Nothing plays here while casting: no silence to keep either.
      _stopSilenceKeepAlive();
      // Cast immediately — don't wait for the reactive listener chain
      final castService = GetIt.instance<CastService>();
      castService.lastCastSlug = station.slug;
      castService.castStation(station);
      setCastPlaying(true);
      return;
    }

    // Track listening session in PostHog
    AnalyticsService.instance.startListening(station.slug, station.title, stationId: station.id);

    // Playlist station: hand off per-item sequencing to the controller.
    if (station.isPlaylist) {
      _isConnecting = false;
      // The playlist's items play on their own: no silence to keep.
      _stopSilenceKeepAlive();
      return _playlistController.startPlaylist(station);
    }

    if (Platform.isAndroid) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (switchId != _stationSwitchId) return;
    }

    // TV station: play video via media_kit when eligible (foreground, no
    // car/cast); otherwise fall through to the just_audio path, which plays
    // the audio track of the HLS/MP4 stream with all existing behavior.
    if (station.isTv &&
        VideoModeDecision.shouldUseVideoMode(
          isVideoContent: true,
          isForeground: isForeground,
          isCarConnected: isCarConnected,
          isCasting: isCasting,
        )) {
      final url = _primaryStreamUrl(station);
      if (url != null && _fallenBackUrl != url) {
        _isConnecting = false;
        return _enterVideoMode(url, live: true);
      }
      if (url != null && _fallenBackUrl == url) {
        // Known-bad video stream for this station — go straight to audio-only
        // with the chip, skipping the doomed video attempt.
        audioOnlyFallback.add(true);
      }
    }

    return play();
  }

  /// The primary (lowest-order) stream URL for [station], used to feed
  /// media_kit for TV video mode. Returns null when the station has no streams.
  String? _primaryStreamUrl(Station station) {
    final streams = Utils.getStationStreamObjects(station.rawStationData);
    if (streams.isEmpty) return null;
    return streams.first['url'];
  }

  @override
  Future<void> seek(Duration position) async {
    // VOD seeking: media_kit in video mode, else just_audio (playlist items).
    // Radio/TV-audio HLS has no scrubber (isLive), so this is a no-op there in
    // practice, but forwarding player.seek is harmless.
    if (_videoMode) {
      await videoService.seek(position);
      _broadcastState(player.playbackEvent);
      return;
    }
    // UI-owned YouTube item: route to the inline iframe (single video only;
    // youtube_playlist is a no-op inside the controller).
    if (_playlistYoutubeActive) {
      await _playlistController.seek(position);
      return;
    }
    await player.seek(position);
  }

  @override
  Future<void> skipToNext() {
    _trace('skipToNext() startedFromFavorites='
        '${stationDataService.startedFromFavorites} '
        'startedFromGroup=${stationDataService.startedFromGroup}');
    // Playlist active: steering-wheel / lock-screen next skips to the next item.
    if (_playlistMode) return _playlistController.skipToNext();
    if (currentStation.value == null) return super.skipToNext();
    final current = currentStation.value!.slug;
    final next = stationDataService.getNextStation(
      current,
      wholeCatalog: isCarConnected,
    );
    _trace('skipToNext: current=$current, next=${next?.slug}');
    if (next == null) return super.skipToNext();
    // A one-station catalog is its own next: playStation resumes it if
    // paused.
    if (next.slug != current) {
      AnalyticsService.instance.trackStationSkip(current, next.slug, 'next');
    }
    return playStation(next);
  }

  @override
  Future<void> skipToPrevious() {
    _trace('skipToPrevious() startedFromFavorites='
        '${stationDataService.startedFromFavorites} '
        'startedFromGroup=${stationDataService.startedFromGroup}');
    if (_playlistMode) return _playlistController.skipToPrevious();
    if (currentStation.value == null) return super.skipToPrevious();
    final current = currentStation.value!.slug;
    final prev = stationDataService.getPreviousStation(
      current,
      wholeCatalog: isCarConnected,
    );
    _trace('skipToPrevious: current=$current, prev=${prev?.slug}');
    if (prev == null) return super.skipToPrevious();
    if (prev.slug != current) {
      AnalyticsService.instance.trackStationSkip(current, prev.slug, 'previous');
    }
    return playStation(prev);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    // The session queue only holds 'Recently played' history rows
    // (_updateSongHistoryQueue), never stations: like playFromMediaId,
    // tapping one keeps the current station playing.
    _trace('skipToQueueItem($index): history queue, ignored');
  }

  /// Determines the playback source for stream tracking.
  ///
  /// Priority order (most specific wins):
  /// 1. CarPlay / Android Auto (car connection active)
  /// 2. AirPlay (iOS audio routed to AirPlay device)
  /// 3. Android TV (leanback hardware)
  /// 4. Phone/tablet (default mobile)
  String _getPlaybackSource() {
    if (isCarConnected) {
      return Platform.isIOS ? 'carplay' : 'android-auto';
    }
    if (Platform.isIOS && flutter_airplay.AirPlayRouteState.instance.isActive) {
      return 'airplay';
    }
    if (TvPlatform.isAndroidTV) {
      return 'android-tv';
    }
    return Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'unknown');
  }

  String addTrackingParametersToUrl(String url) => withTrackingParameters(
        url,
        source: _getPlaybackSource(),
        deviceId: globals.deviceId,
      );

  /// [url] with the stream-analytics parameters: `ref` names the playback
  /// [source] (overwriting any previous one), `s` the device. Existing
  /// parameters are kept.
  static String withTrackingParameters(
    String url, {
    required String source,
    required String deviceId,
  }) {
    final uri = Uri.parse(url);
    final queryParams = Map<String, String>.from(uri.queryParameters);
    queryParams['ref'] = 'radio-crestin-$source';
    queryParams['s'] = deviceId;
    return uri.replace(queryParameters: queryParams).toString();
  }

  @override
  Future<void> play() async {
    _trace("play (isCasting=$isCasting)");
    _resumeAfterInterruption = false;
    // The audio, or the silence while a load runs, keeps the app running.
    unawaited(_pausedStreamTask.end());
    // A play after a pause or stop is the user's resume. Reconnects run
    // while playback is still wanted, and playStation() counted its own.
    final isUserResume = !_hasBeenPlayed && !_isInterruptionResume;
    _isInterruptionResume = false;
    if (isUserResume) _onPlayRequested();
    // Every resume path (Cast, video, playlist, fast resume, reload) is a
    // listening session, as pause() ends one on each; a no-op right after
    // playStation() started one.
    final station = currentStation.valueOrNull;
    if (station != null) {
      AnalyticsService.instance
          .ensureListening(station.slug, station.title, stationId: station.id);
      if (isUserResume) _countReviewAction();
    }
    if (isCasting) {
      // Resume playback on Cast — just send play(), don't reload media.
      // Optimistic UI via setCastPlaying so the notification icon flips
      // to pause immediately; the receiver's PLAYING MediaStatus will
      // re-confirm shortly via the main.dart state sync listener.
      _hasBeenPlayed = true;
      GetIt.instance<CastService>().play();
      setCastPlaying(true);
      _disconnectTimer?.cancel();
      stationDataService.resumePolling();
      return;
    }
    // Video mode: media_kit owns playback — resume it, not just_audio.
    if (_videoMode) {
      _hasBeenPlayed = true;
      // A play from the lock screen or a headset while backgrounded must
      // not resume the video decoder there: switch to audio-only, as the
      // background handoff does.
      final backgrounded = _lifecycleState == AppLifecycleState.paused ||
          _lifecycleState == AppLifecycleState.hidden;
      if (backgrounded && !_playlistMode) return _handoffTvVideoToAudio();
      _trace('play: resuming video mode');
      _disconnectTimer?.cancel();
      stationDataService.resumePolling();
      await videoService.play();
      _broadcastState(player.playbackEvent);
      return;
    }
    // Playlist mode: youtube items are UI-owned (route to the inline iframe);
    // audio/video VOD items resume the just_audio player directly (the
    // station-stream retry loop below does not apply to playlist items).
    if (_playlistMode) {
      _hasBeenPlayed = true;
      _disconnectTimer?.cancel();
      stationDataService.resumePolling();
      if (_playlistYoutubeActive) {
        _trace('play: resuming youtube item');
        _playlistController.resumeYoutube();
        return;
      }
      _trace('play: resuming playlist audio item');
      await _playPlayer();
      return;
    }
    _disconnectTimer?.cancel();
    stationDataService.resumePolling();
    _hasBeenPlayed = true;

    var item = mediaItem.valueOrNull;

    // Fast resume: if a stream is already loaded for this station, just resume playback.
    // _loadedStreamUrl is nulled on station change, pause-disconnect, and stop,
    // so non-null means the current station's stream is still loaded.
    if (_loadedStreamUrl != null &&
        player.processingState != ProcessingState.idle) {
      // Fix 2 — re-anchor on stale resume. For live HLS the DVR window slides
      // while paused: the paused playhead sits `offset` behind live, so after
      // enough wall-clock time the window's trailing edge evicts its segment
      // and resuming in place would silently stall (AVPlayer sits `ready` but
      // never advances). If we've been paused past the safe runway, drop the
      // loaded URL and fall through to a fresh load so _seekBehindLiveEdge()
      // re-anchors. Direct/non-HLS streams have no window — always fast-resume.
      // Measured from the real stop (any cause, not only a pause() call);
      // the playing check covers a play() racing the playing listener.
      final stoppedAt = player.playing ? null : _stoppedPlayingAt;
      final pausedFor = stoppedAt == null
          ? Duration.zero
          : DateTime.now().difference(stoppedAt);
      final reload = _loadedStreamType == 'HLS' &&
          ReconnectPolicy.shouldReloadAfterPause(
            offset: SeekModeManager.currentOffset,
            windowDepth: player.duration,
            pausedFor: pausedFor,
          );
      // An item loaded through the hold proxy reaches nothing once the
      // proxy listens on another port: iOS may reclaim a suspended app's
      // listening socket, and the restart may not get the port back.
      final proxyUrl = _loadedProxyUrl;
      var proxyMoved = false;
      if (!reload && proxyUrl != null) {
        final switchId = _stationSwitchId;
        proxyMoved = !await _holdProxyServes(proxyUrl);
        // A pause, stop or station switch came in meanwhile.
        if (switchId != _stationSwitchId) return;
      }
      if (!reload && !proxyMoved) {
        _trace("play: fast resume (stream already loaded)");
        return _playPlayer();
      }
      _trace(proxyMoved
          ? 'play: the hold proxy moved to another port since the load — '
              'reloading'
          : 'play: paused ${pausedFor.inSeconds}s exceeds safe DVR runway — '
              'reloading to re-anchor behind live edge');
      _loadedStreamUrl = null;
      _loadedStreamType = null;
    }

    // A play while this station's stream is loading (a tap on a car's or a
    // headset's play button, a duplicate tap) keeps that load: restarting
    // would try the same stream again from the start, adding up to its
    // whole load timeout. A loop waiting out its backoff is restarted
    // below, to try again now.
    if (_isLoadingStation(currentStation.valueOrNull)) {
      _trace('play: already loading this station, keeping that load');
      return;
    }

    // Need to load a new stream source. Claim the operation first: cancel
    // any older retry loop still cycling (one waiting out its backoff, a
    // zombie reconnect) so exactly one loop drives the player — the loops
    // never give up on their own anymore, so a stale one must be cancelled
    // here.
    _cancelInFlightPlay();
    final myOpId = _playOperationId;
    PerformanceMonitor.startOperation('audio_play');
    _isConnecting = true;
    _broadcastState(player.playbackEvent);
    // No audio comes out until a stream plays. iOS takes the playing state
    // that CarPlay and the lock screen show from the audio coming out, and
    // suspends a silent app in the background (the loop, its timers and
    // the network-restored reconnect with it): the silence keeps the pause
    // button there, and the app running, until the stream plays.
    if (Platform.isIOS) unawaited(_startSilenceKeepAlive());
    var retry = 0;
    Object? lastError;
    // The loop never gives up: past its first passes, failures are summed
    // up instead of logged one by one.
    final retryLog = RetryLogThrottle();
    // Retry-cycle start index — computed once from the failure memory so a
    // reconnect after a mid-playback HLS death starts at the next healthy
    // stream instead of re-looping on the dead one (the old `retry % total`
    // always restarted at index 0).
    int? cycleStart;
    // The connection-error toast fires once per play() call, after the
    // first full failed pass the internet was up for (see
    // _surfaceConnectionError). The loop itself never gives up (live
    // radio): it keeps cycling with capped backoff until cancelled or
    // superseded.
    var passStartedAt = DateTime.now();
    var passStartedOffline = false;
    final canceller = Completer<void>();
    _sourceLoadCanceller = canceller;
    _loadingStationId = item?.extras?['station_id'];
    final previousStreamInfo = currentStreamInfo.valueOrNull;
    // Where the loaded start variant begins behind live; null when the
    // stream's own URL loaded.
    Duration? startVariantOffset;

    while (item != null && myOpId == _playOperationId) {
      if (_restartPassAtPreferred) {
        _restartPassAtPreferred = false;
        retry = 0;
        cycleStart = null;
      }
      var streams = item.extras?["station_streams"] as List<dynamic>?;
      // Desktop (Linux/Windows) uses just_audio_media_kit (libmpv ~2023-09) which
      // has flaky support for HLS v9 with query params. Prefer direct streams there.
      if (streams != null && (Platform.isWindows || Platform.isLinux)) {
        final reordered = List<dynamic>.from(streams);
        reordered.sort((a, b) {
          final aHls = (a is Map && a["type"]?.toString() == 'HLS') ? 1 : 0;
          final bHls = (b is Map && b["type"]?.toString() == 'HLS') ? 1 : 0;
          return aHls - bHls;
        });
        streams = reordered;
      }
      final totalStreams = streams?.length ?? 0;
      final stationSlug = item.extras?["station_slug"]?.toString() ?? '';
      final stationId = item.extras?["station_id"];
      final stationTitle = item.extras?["station_title"]?.toString() ?? '';

      final start = cycleStart ?? _cycleStartIndex(streams, stationSlug);
      cycleStart = start;
      final attemptIndex =
          totalStreams == 0 ? 0 : (start + retry) % totalStreams;
      final streamEntry = (streams == null || streams.isEmpty)
          ? null
          : streams[attemptIndex];
      final streamUrl = (streamEntry is Map ? streamEntry["url"] : streamEntry)?.toString() ?? item.id;
      final streamType = streamEntry is Map ? streamEntry["type"]?.toString() : null;
      final isHls = streamType == 'HLS';

      // Cycle backoff: streams fail over to each other instantly; a delay
      // applies only once every stream has failed a full pass (1s, 2s, 5s,
      // then 10s cap — see StreamFailover.retryDelay; 30s while waiting for
      // the network, see ReconnectPolicy.waitsForNetwork).
      final network = NetworkService.instance;
      final delay = ReconnectPolicy.retryBackoff(
        StreamFailover.retryDelay(retry: retry, totalStreams: totalStreams),
        offline: ReconnectPolicy.waitsForNetwork(
          status: network.status.value,
          noInternetSince: _noInternetSince,
          now: DateTime.now(),
        ),
      );
      if (delay > Duration.zero) {
        _log('play: all streams failed a full cycle — backing off '
            '${delay.inMilliseconds}ms before attempt $retry');
        // The network returning cuts the wait short: reconnectIfNeeded()
        // skips while this loop runs, so without it the audio would come
        // back only when the backoff ran out.
        final networkBack = _retryBackoffWake = Completer<void>();
        try {
          await Future.any([
            Future<void>.delayed(delay),
            canceller.future,
            networkBack.future,
          ]);
        } catch (_) {
          // canceller completes with an error on cancel; the opId check
          // below exits the loop.
        }
        if (identical(_retryBackoffWake, networkBack)) {
          _retryBackoffWake = null;
        }
        if (myOpId != _playOperationId) break;
        // Woken by the network: pick the stream again, from the top.
        if (_restartPassAtPreferred) continue;
      }
      if (retry % (totalStreams == 0 ? 1 : totalStreams) == 0) {
        passStartedAt = DateTime.now();
        passStartedOffline = network.isOffline.value;
      }

      _log("play: attempt $retry - $streamUrl (type: $streamType)");
      _recordStreamEvent(
        StreamEventKind.attempt,
        'Attempt ${attemptIndex + 1}/$totalStreams ${streamType ?? '?'}',
      );
      // Debug-only: high volume on healthy connections. Errors and switches
      // still ship in production via capture() below.
      if (retryLog.isDetailed(retry: retry, totalStreams: totalStreams)) {
        AnalyticsService.instance.captureDebug('stream_attempt', {
          'station_slug': stationSlug,
          if (stationId != null) 'station_id': stationId,
          'stream_url': streamUrl,
          'stream_type': streamType,
          'stream_index': attemptIndex,
          'total_streams': totalStreams,
          'retry': retry,
          'player_backend': isVideoModeActive ? 'media_kit' : 'just_audio',
        });
      }

      final attemptStart = DateTime.now();
      try {
        if (retry > 0) {
          await player.stop();
        }
        // New load: forget the previous stream's timeline. For HLS, fetch
        // the playlist concurrently with the player's own fetch, so the
        // anchoring snapshot shows (nearly) the window the player sees.
        final hlsGeneration = _beginHlsLoad();
        if (isHls) {
          unawaited(
              _pollHlsPlaylist(url: streamUrl, generation: hlsGeneration));
        }
        final loaded = await _loadStreamSource(
          streamUrl,
          isHls: isHls,
          canceller: canceller.future,
          opId: myOpId,
        );
        startVariantOffset = loaded.startVariantOffset;
        _loadedStreamUrl = streamUrl;
        _loadedProxyUrl = loaded.proxyUrl;
        _loadedStreamType = streamType;
        _lastSuccessfulLoadAt = DateTime.now();
        _failover.recordSuccess(streamUrl);
        final elapsedMs = DateTime.now().difference(attemptStart).inMilliseconds;
        _log("play: source loaded successfully (${loaded.url})");

        final newInfo = StreamInfo(
          url: streamUrl,
          type: streamType,
          attemptIndex: attemptIndex,
          totalStreams: totalStreams,
          stationSlug: stationSlug,
          stationTitle: stationTitle,
          loadedAt: DateTime.now(),
        );
        currentStreamInfo.add(newInfo);
        AnalyticsService.instance.setCurrentStream(
          url: streamUrl,
          type: streamType,
          index: attemptIndex,
          total: totalStreams,
        );
        NetworkService.instance.reportRequestSuccess();

        _recordStreamEvent(
          StreamEventKind.loaded,
          '${streamType ?? '?'} loaded in ${elapsedMs}ms',
        );
        // The stream that actually plays: `listening started` fires before
        // the load and can't say. For HLS, `variant_url` is the start
        // variant loaded and `start_variant_s` how far behind live it
        // begins; without them the stream's own URL loaded, with a seek
        // behind live. Never `loaded.url`: its tracking parameters carry
        // the device id.
        final startVariant = loaded.startVariantOffset;
        AnalyticsService.instance.log('stream_loaded', {
          'station_slug': stationSlug,
          if (stationId != null) 'station_id': stationId,
          'stream_url': streamUrl,
          'stream_type': streamType,
          'stream_index': attemptIndex,
          'total_streams': totalStreams,
          'elapsed_ms': elapsedMs,
          'retry': retry,
          if (startVariant != null) ...{
            'variant_url': HlsStartVariant.urlFor(streamUrl, startVariant),
            'start_variant_s': startVariant.inSeconds,
          },
          if (loaded.proxyUrl != null) 'hold_proxy': true,
        });

        // Fire stream_switched only when the loaded URL differs from the
        // previously-loaded URL — distinguishes a true fallback switch from
        // a same-stream reconnect.
        if (previousStreamInfo != null && previousStreamInfo.url != streamUrl) {
          final reason = previousStreamInfo.stationSlug != stationSlug
              ? 'station_change'
              : (retry > 0
                  ? 'load_failed_fallback'
                  : (start > 0
                      ? 'failure_memory_skip'
                      : 'reconnect_to_different'));
          _recordStreamEvent(
            StreamEventKind.switched,
            'Switched to ${streamType ?? '?'} #${attemptIndex + 1} ($reason)',
          );
          final switchedProps = <String, Object?>{
            'station_slug': stationSlug,
            if (stationId != null) 'station_id': stationId,
            'reason': reason,
            'previous_url': previousStreamInfo.url,
            'new_url': streamUrl,
            'previous_type': previousStreamInfo.type,
            'new_type': streamType,
            'previous_index': previousStreamInfo.attemptIndex,
            'new_index': attemptIndex,
            'retry_count': retry,
            'ms_since_last_load':
                DateTime.now().difference(previousStreamInfo.loadedAt).inMilliseconds,
          };
          AnalyticsService.instance.log('stream switched', switchedProps);
        }
        break;
      } catch (e) {
        lastError = e;
        final elapsedMs = DateTime.now().difference(attemptStart).inMilliseconds;
        _loadedStreamUrl = null;
        _loadedStreamType = null;
        // If superseded by a newer playStation(), exit immediately
        if (myOpId != _playOperationId) {
          _trace("play: cancelled (op $myOpId < $_playOperationId)");
          break;
        }
        _recordStreamFailure(streamUrl, DateTime.now());
        // An HTTP error status is still an answer: the internet works, the
        // station's server is the problem.
        if (_isHttpStatusError(e)) {
          network.reportRequestSuccess();
        } else {
          network.reportRequestFailure();
        }
        _log("play: attempt $retry failed - $e");
        _recordStreamEvent(
          StreamEventKind.failed,
          'Attempt ${attemptIndex + 1}/$totalStreams failed (${elapsedMs}ms): ${_shortErr(e)}',
        );
        final failedProps = <String, Object?>{
          'station_slug': stationSlug,
          if (stationId != null) 'station_id': stationId,
          'stream_url': streamUrl,
          'stream_type': streamType,
          'stream_index': attemptIndex,
          'total_streams': totalStreams,
          'retry': retry,
          'elapsed_ms': elapsedMs,
          'error': _shortErr(e),
        };
        if (retryLog.isDetailed(retry: retry, totalStreams: totalStreams)) {
          AnalyticsService.instance
              .logWarning('stream attempt failed', failedProps);
        } else {
          final failures = retryLog.quietFailure(DateTime.now());
          if (failures != null) {
            AnalyticsService.instance.logWarning('stream retrying', {
              ...failedProps,
              'failed_attempts': failures,
            });
          }
        }
        retry++;
        // Every stream failed a full pass: surface the error once (toast
        // + analytics) but keep the spinner and keep cycling — stopping
        // here (the old maxRetries=4 behavior) left the player fully
        // stuck until a manual tap, even after the network recovered.
        final cycleSize = totalStreams == 0 ? 1 : totalStreams;
        if (retry % cycleSize == 0 &&
            _errorShownForOp != myOpId &&
            _errorPendingForOp != myOpId) {
          unawaited(_surfaceConnectionError(
            lastError,
            opId: myOpId,
            passStartedAt: passStartedAt,
            passStartedOffline: passStartedOffline,
            properties: {
              'station_slug': stationSlug,
              'station_id': stationId,
              'total_streams': totalStreams,
              'retries': retry,
            },
          ));
        }
      }
    }

    // Bail out if a newer play() call has superseded this one — before
    // touching the shared connection state, which is the newer call's now:
    // clearing it cut the newer loop's spinner, its reconnect guard and its
    // error toast (a play from the lock screen, a headset or the car while
    // a retry loop was waiting).
    if (myOpId != _playOperationId) {
      _trace("play: superseded (op $myOpId < $_playOperationId), aborting");
      // Its own measurement: the monitor pairs starts and ends in order.
      PerformanceMonitor.endOperation('audio_play');
      return;
    }

    _sourceLoadCanceller = null;
    PerformanceMonitor.endOperation('audio_play');

    var reloadAtLivePoint = false;
    if (_loadedStreamType == 'HLS') {
      final offset = SeekModeManager.currentOffset;
      _anchoredOffset = offset;
      switch (HlsStartVariant.followUp(
        variantOffset: startVariantOffset,
        currentOffset: offset,
        seekRestartsPlayback: _reloadNeedsSeekToPlay,
      )) {
        case HlsStartFollowUp.none:
          _trace('play: the start variant already begins ${offset.inSeconds}s '
              'behind live, no seek');
        case HlsStartFollowUp.restart:
          _restartWhereLoaded();
        case HlsStartFollowUp.seek:
          _seekBehindLiveEdge(); // non-blocking: seek starts, play() follows immediately
        case HlsStartFollowUp.reload:
          // Instant mode came on while the variant loaded, and the reload
          // the setting asked for (reapplySeekOffset) skipped the load in
          // flight. It runs once this plays, from the offset the stream
          // really starts at.
          _trace('play: instant mode came on while the start variant loaded, '
              'reloading at the live point');
          _anchoredOffset = startVariantOffset;
          reloadAtLivePoint = true;
      }
      // The concurrent fetch issued with the load is already in flight.
      _startHlsPlaylistPoll(skipInitialFetch: true);
    } else {
      _stopHlsPlaylistRefresh();
    }
    // The watchdog's run condition includes the loaded stream, which just
    // changed. A reload while playing (liveness recovery, offset change)
    // never flips `playing`, so the playing listener would not re-sync it.
    _syncLiveHlsWatchdog();

    // play() reports playing at once. Connecting ends only after it: in
    // between, a reconnect that stopped the player (see
    // _isReconnectingOnIntent) would tell the session it paused, and
    // audio_service would leave the foreground for good in the background.
    final playback = _playPlayer();
    _isConnecting = false;
    // The stream's audio takes over from the silence started with the load.
    _stopSilenceKeepAlive();
    _broadcastState(player.playbackEvent);
    if (reloadAtLivePoint) unawaited(reapplySeekOffset());
    return playback;
  }

  /// Plays the loaded source on the local player, reporting buffering
  /// until its state shows the play (see [playerWaitsAfterPlay]).
  Future<void> _playPlayer() {
    final awaitsStart = playerWaitsAfterPlay &&
        !player.playing &&
        player.processingState == ProcessingState.ready;
    if (awaitsStart) {
      _awaitingAudioStart = true;
      _audioStartRequestedAt = null;
    }
    final playback = player.play();
    // Taken after play(): the event it emits itself predates the play.
    if (awaitsStart) _audioStartRequestedAt = DateTime.now();
    return playback;
  }

  /// Ends the wait of [_playPlayer] at the player's first [event] since
  /// the play.
  ///
  /// AVPlayer answers a play at once, with its wait for data (buffering)
  /// or, should it have enough, its start (ready), and stamps the event
  /// with the time it handled the play (see [mayAnswerPlay]).
  void _endAwaitingAudioStart(PlaybackEvent event) {
    final requestedAt = _audioStartRequestedAt;
    if (!_awaitingAudioStart ||
        requestedAt == null ||
        !mayAnswerPlay(event.updateTime, requestedAt)) {
      return;
    }
    _awaitingAudioStart = false;
    _audioStartRequestedAt = null;
  }

  /// Whether a player event stamped [eventTime] can answer a play asked
  /// at [requestedAt]: one stamped earlier was on its way before it.
  ///
  /// AVPlayer stamps its events in whole milliseconds, so its answer in
  /// the millisecond of the request reads as earlier than the request.
  /// Compared to the microsecond, that answer would be missed, and as
  /// nothing stamps again during steady playback, playing would show as
  /// buffering until the next pause or stall.
  @visibleForTesting
  static bool mayAnswerPlay(DateTime eventTime, DateTime requestedAt) =>
      eventTime.millisecondsSinceEpoch >= requestedAt.millisecondsSinceEpoch;

  /// Loads [streamUrl] into the player with the tracking parameters,
  /// racing [canceller] under the stream's load timeout, for play()'s
  /// attempt [opId]. Returns the URL loaded, the hold proxy URL the player
  /// loaded it from (null: directly, see [_holdProxyFor]) and, for a start
  /// variant (see [HlsStartVariant]), the offset behind live it begins at.
  ///
  /// A live HLS stream at the 2- or 5-minute offset loads its variant.
  /// When that load fails as a variant the origin does not publish does
  /// ([HlsStartVariant.mayBeMissing]), the stream loads again at once from
  /// its own URL, in the same attempt. That is no stream failure (no
  /// failover, toast or network report): the stream itself may well be
  /// fine. Once that load succeeds, the stream is remembered for the
  /// session. Any other error, the fallback's included, is the caller's,
  /// as before.
  ///
  /// A load through the hold proxy that fails before the origin answered
  /// any of its requests may be the proxy's own failure (see
  /// [_mayBypassHoldProxy]): the URL then loads again at once directly,
  /// and once that succeeds, the stream skips the proxy until the device
  /// moves to another network.
  Future<({String url, String? proxyUrl, Duration? startVariantOffset})>
      _loadStreamSource(
    String streamUrl, {
    required bool isHls,
    required Future<void> canceller,
    required int opId,
  }) async {
    // Hard load timeout — a hanging playlist/stream request counts as
    // a failure and advances to the next stream (StreamFailover owns
    // the values so they are asserted in tests).
    final timeout = StreamFailover.loadTimeout(isHls: isHls);
    Future<void> loadPlayer(String uri) async {
      // Race setAudioSource against the canceller so playStation() can
      // break this await immediately instead of waiting for the timeout.
      final loadFuture = player.setAudioSource(
        AudioSource.uri(Uri.parse(uri)),
        preload: true,
      );
      // Prevent unhandled error if abandoned by Future.any
      loadFuture.ignore();
      await Future.any([loadFuture, canceller]).timeout(timeout);
    }

    // Listeners are counted from the tracking parameters, so the variant
    // carries them too, and so does the request the hold proxy makes. The
    // app keeps the URL itself: the proxy URL is the player's alone.
    Future<({String url, String? proxyUrl})> load(String url) async {
      final trackedUrl = addTrackingParametersToUrl(url);
      final proxy = _streamsWithoutHoldProxy.contains(streamUrl)
          ? null
          : _holdProxyFor(trackedUrl, isHls: isHls);
      final proxied = proxy == null
          ? null
          : await Future.any([
              _holdProxyUrl(proxy, trackedUrl, opId),
              canceller.then((_) => null),
            ]);
      // A newer load took over while the proxy got ready.
      if (opId != _playOperationId) throw StateError('load superseded');
      if (proxy == null || proxied == null) {
        await loadPlayer(trackedUrl);
        return (url: trackedUrl, proxyUrl: null);
      }
      try {
        await loadPlayer(proxied.url);
        return (url: trackedUrl, proxyUrl: proxied.url);
      } catch (e) {
        if (!_mayBypassHoldProxy(e, proxy, proxied.session, opId)) rethrow;
        _trace('play: the load through the hold proxy failed before the '
            'origin answered (${_shortErr(e)}), loading $url directly');
        // A fresh native player, as for every retry in play().
        await player.stop();
        if (opId != _playOperationId) rethrow;
        await loadPlayer(trackedUrl);
        // Only now is the proxy suspect: the origin answers without it. Had
        // this load failed too, the network or the origin would explain
        // both, and the next load goes through the proxy again.
        _streamsWithoutHoldProxy.add(streamUrl);
        AnalyticsService.instance.logWarning('stream hold proxy bypassed', {
          'station_slug': currentStation.valueOrNull?.slug,
          'stream_url': streamUrl,
          'error': _shortErr(e),
        });
        return (url: trackedUrl, proxyUrl: null);
      }
    }

    final offset = SeekModeManager.currentOffset;
    final variantUrl = isHls &&
            HlsStartVariant.isSupportedPlatform &&
            !_streamsWithoutStartVariant.contains(streamUrl)
        ? HlsStartVariant.urlFor(streamUrl, offset)
        : null;
    if (variantUrl == null) {
      final loaded = await load(streamUrl);
      return (
        url: loaded.url,
        proxyUrl: loaded.proxyUrl,
        startVariantOffset: null,
      );
    }
    try {
      final loaded = await load(variantUrl);
      return (
        url: loaded.url,
        proxyUrl: loaded.proxyUrl,
        startVariantOffset: offset,
      );
    } catch (e) {
      final missing = HlsStartVariant.mayBeMissing(
        e,
        httpStatus: _isHttpStatusError(e),
        android: Platform.isAndroid,
        offline: NetworkService.instance.isOffline.value,
      );
      if (opId != _playOperationId || !missing) rethrow;
      _log('play: start variant $variantUrl failed (${_shortErr(e)}), '
          'loading $streamUrl with the seek behind live instead');
      // A fresh native player, as for every retry in play().
      await player.stop();
      if (opId != _playOperationId) rethrow;
      final loaded = await load(streamUrl);
      // Only now is the variant what is missing: the origin answers for
      // the stream itself. Had that load failed too, the network or the
      // stream would explain both (a pod restarting, a dropped signal),
      // and the stream's next load tries the variant again.
      _streamsWithoutStartVariant.add(streamUrl);
      AnalyticsService.instance.logDebug('hls start variant unavailable', {
        'stream_url': streamUrl,
        'variant_url': variantUrl,
        'error': _shortErr(e),
      });
      return (
        url: loaded.url,
        proxyUrl: loaded.proxyUrl,
        startVariantOffset: null,
      );
    }
  }

  // ── Hold proxy (iOS) ──────────────────────────────────────────────────

  /// The hold proxy to load [url] through, created at the first need: a
  /// live HLS stream ([isHls]) of the origin, on iOS (see
  /// [holdProxyPlatform]), the remote kill switch on. Null to load [url]
  /// directly.
  ///
  /// Only the player's requests go through it: the app's own playlist
  /// polls, the timeline and Cast use the stream's URL.
  HlsHoldProxy? _holdProxyFor(String url, {required bool isHls}) {
    if (!isHls || !holdProxyPlatform || !HlsHoldProxyFlag.instance.enabled) {
      return null;
    }
    final host = Uri.tryParse(url)?.host;
    if (host == null || !HlsStartVariant.hosts.contains(host)) return null;
    return _holdProxy ??= _createHoldProxy();
  }

  /// The URL the player loads [trackedUrl] from through [proxy], in a new
  /// session, and that session, for play()'s attempt [opId]; null, to load
  /// [trackedUrl] directly, when the proxy cannot listen, or when a newer
  /// load took over meanwhile (its session must stay the current one).
  Future<({String url, int session})?> _holdProxyUrl(
    HlsHoldProxy proxy,
    String trackedUrl,
    int opId,
  ) async {
    if (!await proxy.ensureRunning() || opId != _playOperationId) return null;
    final session = proxy.beginSession();
    final url = proxy.wrap(trackedUrl, session);
    return url == null ? null : (url: url, session: session);
  }

  /// Whether a load through the hold proxy, in its [session], that failed
  /// with [error] may have failed for the proxy's own sake, so that play()'s
  /// attempt [opId] loads the URL directly instead.
  ///
  /// Only when the origin answered none of the session's requests: an HTTP
  /// status is that answer, and so is any response the proxy got. The
  /// proxy's way to the origin is dart:io's, not the system's: a network
  /// that requires an HTTP proxy (corporate, school, hotel WiFi), or a TLS
  /// or HTTP/1.1 fault on the way, fails every load through it while the
  /// player alone would play. Not without any network: nothing would load.
  bool _mayBypassHoldProxy(
    Object error,
    HlsHoldProxy proxy,
    int session,
    int opId,
  ) =>
      opId == _playOperationId &&
      !_isHttpStatusError(error) &&
      !proxy.originAnswered(session) &&
      NetworkService.instance.status.value != ConnectionStatus.offline;

  HlsHoldProxy _createHoldProxy() {
    final network = NetworkService.instance;
    // A switch between WiFi and mobile data leaves the upstream requests
    // and connections on the network that left, where they would hang.
    // The proxy may work on the new network where it failed on the last.
    _holdProxyNetworkSub = network.isOnMobileData.stream.skip(1).listen((_) {
      _holdProxy?.networkChanged();
      _streamsWithoutHoldProxy.clear();
    });
    return HlsHoldProxy(
      allowedHosts: HlsStartVariant.hosts,
      isOffline: () => network.isOffline.value,
      offlineChanges: network.isOffline.stream,
      onEvent: _onHoldProxyEvent,
    );
  }

  /// Whether the loaded item's [proxyUrl] still reaches the hold proxy,
  /// which is restarted first if it stopped listening (see
  /// [HlsHoldProxy.ensureRunning]).
  Future<bool> _holdProxyServes(String proxyUrl) async {
    final proxy = _holdProxy;
    return proxy != null &&
        await proxy.ensureRunning() &&
        proxy.serves(proxyUrl);
  }

  /// Logs the hold proxy's holds (never its normal requests), and reports
  /// the failures it hides from the player to NetworkService: a held
  /// request is the outage's only sign from the player's side, and a
  /// tunnel changes no network.
  void _onHoldProxyEvent(HlsHoldProxyEvent e) {
    final error = e.error == null ? null : HlsHoldProxy.describe(e.error!);
    switch (e.kind) {
      case HlsHoldProxyEventKind.holdStarted:
        NetworkService.instance.reportRequestFailure();
        _log('hold proxy: holding ${e.resource} (session ${e.session}): '
            '$error');
        AnalyticsService.instance.logDebug('stream hold started', {
          'station_slug': currentStation.valueOrNull?.slug,
          'resource': e.resource,
          'session': e.session,
          'error': error,
        });
      case HlsHoldProxyEventKind.holdRetryFailed:
        NetworkService.instance.reportRequestFailure();
      case HlsHoldProxyEventKind.holdEnded:
        final held = (e.held?.inMilliseconds ?? 0) / 1000;
        _log('hold proxy: ${e.resource} held ${held}s, '
            '${e.endReason?.name} (${e.attempts} tries)');
        AnalyticsService.instance.logDebug('stream hold ended', {
          'station_slug': currentStation.valueOrNull?.slug,
          'resource': e.resource,
          'session': e.session,
          'held_s': held,
          'reason': e.endReason?.name,
          'attempts': e.attempts,
          'status': e.status,
          if (e.endReason != HlsHoldEnd.answered) 'error': error,
        });
      case HlsHoldProxyEventKind.failedFast:
        // The player's load fails, which play() logs.
        _log('hold proxy: ${e.resource} failed at once '
            '(session ${e.session}): $error');
      case HlsHoldProxyEventKind.serverStarted:
      case HlsHoldProxyEventKind.serverClosed:
        _trace('hold proxy: ${e.kind.name} (port ${e.port}'
            '${error == null ? '' : ', $error'})');
      case HlsHoldProxyEventKind.internalError:
        AnalyticsService.instance.logWarning('stream hold proxy error', {
          'resource': e.resource,
          'session': e.session,
          'error': error,
        });
      case HlsHoldProxyEventKind.responded:
        // Only with traceResponses, which the app leaves off.
        break;
    }
  }

  /// The hold proxy, once a load needed it.
  @visibleForTesting
  HlsHoldProxy? get debugHoldProxy => _holdProxy;

  /// Retry-cycle start index for [streams]: the first stream without a
  /// recent failure (see [StreamFailover.startIndex]). Logs a
  /// `stream failover` record when the preferred stream is being skipped so
  /// failovers are visible in PostHog Logs.
  int _cycleStartIndex(List<dynamic>? streams, String stationSlug) {
    if (streams == null || streams.isEmpty) return 0;
    final urls = [
      for (final s in streams) (s is Map ? s["url"] : s)?.toString() ?? '',
    ];
    final start = _failover.startIndex(urls, DateTime.now());
    if (start > 0) {
      _log('play: failover — skipping $start recently-failed stream(s), '
          'starting at index $start (${urls[start]})');
      AnalyticsService.instance.log('stream failover', {
        'station_slug': stationSlug,
        'skipped_urls': urls.take(start).join(', '),
        'start_index': start,
        'start_url': urls[start],
        'total_streams': urls.length,
        'reason': 'recent_failure',
      });
    }
    return start;
  }

  /// Remembers [url] as failed, so the next retry cycle starts at another
  /// stream (see [StreamFailover]).
  ///
  /// Not while the internet is out: every stream fails then, and blaming
  /// the preferred HLS stream would bring the audio back on the fallback
  /// once the network returns, without the forward buffer that rides out
  /// the next drop.
  void _recordStreamFailure(String url, DateTime now) {
    if (NetworkService.instance.isOffline.value) {
      _log('failover: $url failed without internet, not blamed');
      return;
    }
    _failover.recordFailure(url, now);
  }

  @override
  Future<void> pause() async {
    _trace("pause (isCasting=$isCasting)");
    // Cancels a station switch in flight (playStation re-checks this after
    // each await) and the loading state it set, which the cast and
    // playlist branches would otherwise leave behind.
    _stationSwitchId++;
    _isConnecting = false;
    _resumeAfterInterruption = false;
    if (isCasting) {
      _hasBeenPlayed = false;
      AnalyticsService.instance.endListening(reason: 'pause');
      GetIt.instance<CastService>().pause();
      setCastPlaying(false);
      return;
    }
    // Video mode: pause media_kit (no disconnect timer — the source stays warm).
    if (_videoMode) {
      _hasBeenPlayed = false;
      AnalyticsService.instance.endListening(reason: 'pause');
      await videoService.pause();
      _broadcastState(player.playbackEvent);
      return;
    }
    // Playlist mode: youtube items are UI-owned (pause the inline iframe);
    // audio/video items pause just_audio directly, skipping the 60s
    // station-stream disconnect timer (there is no station stream to drop).
    if (_playlistMode) {
      _hasBeenPlayed = false;
      AnalyticsService.instance.endListening(reason: 'pause');
      if (_playlistYoutubeActive) {
        _trace('pause: pausing youtube item');
        _playlistController.pauseYoutube();
        return super.pause();
      }
      await player.pause();
      _broadcastState(player.playbackEvent);
      return super.pause();
    }
    _cancelInFlightPlay();
    _hasBeenPlayed = false;
    // A pause mid-buffering must not leave the stall reattempt armed or
    // the iOS silence keeper looping until the disconnect.
    _bufferingStallTimer?.cancel();
    _stopSilenceKeepAlive();
    _stopLiveHlsWatchdog();
    AnalyticsService.instance.endListening(reason: 'pause');
    await player.pause();
    // During a station switch the player is already stopped (or paused),
    // so pause() emits nothing and the switch's loading state would linger.
    _broadcastState(player.playbackEvent);
    // The audible clock is frozen while paused; the timeline listener also
    // cancels on advancing=false, this keeps the intent explicit. The poll
    // keeps running (skew and boundaries stay fresh) until the disconnect.
    _cancelSongBoundaryTimer();

    // Disconnect after 60s of being paused to save bandwidth.
    // If the user resumes within 60s, play() will fast-resume without reconnecting.
    _disconnectTimer?.cancel();
    _disconnectTimer = Timer(_disconnectDelay, () {
      _trace("pause: disconnecting idle stream after ${_disconnectDelay.inSeconds}s");
      unawaited(_pausedStreamTask.end());
      _loadedStreamUrl = null;
      _loadedStreamType = null;
      // The paused title stays until resume (the resume reloads and
      // re-anchors), so aligned playback does not end here.
      _stopHlsPlaylistRefresh(endAlignedPlayback: false);
      currentStreamInfo.add(null);
      AnalyticsService.instance.setCurrentStream(url: null, type: null, index: null, total: null);
      // Fire-and-forget idle preload. A later play()/resume can supersede it,
      // making just_audio throw PlayerInterruptedException("Loading
      // interrupted") as an unhandled async error. ignore() absorbs it — the
      // load result is irrelevant here. (PostHog 019d71a4…)
      player
          .setAudioSource(
            AudioSource.uri(Uri.parse(CONSTANTS.STATIC_MP3_URL)),
            preload: false,
          )
          .ignore();
      // Keep polling if car or cast is connected — user sees metadata on screen
      final carConnected = GetIt.instance.isRegistered<CarPlayService>() &&
          GetIt.instance<CarPlayService>().isConnected;
      if (!carConnected && !isCasting) {
        stationDataService.pausePolling();
      }
    });
    if (pausedStreamBackgroundTimePlatform && _isLocalLiveHls) {
      _trace('pause: holding iOS background time for the loaded buffer');
      unawaited(_pausedStreamTask.begin());
    }

    return super.pause();
  }

  /// Applies a new seek offset: restarts the HLS stream if currently
  /// playing. The station list is live and does not depend on the offset;
  /// the reload's anchored refresh re-resolves the playing station's song.
  Future<void> reapplySeekOffset() async {
    if (_loadedStreamType != 'HLS' || !player.playing) return;
    // When the offset is already in effect (5-min mode, unstable or
    // auto-slow) a reload would only cut the audio for nothing.
    if (SeekModeManager.currentOffset == _anchoredOffset) {
      _trace('reapplySeekOffset: offset unchanged, skipping');
      return;
    }
    _trace('reapplySeekOffset: restarting HLS stream with new offset');
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    await play();
  }

  /// Re-emits the current media item so that thumbnail and metadata reflect
  /// the latest data-saving settings (unstable connection, mobile data, etc.).
  void refreshCurrentMetadata() {
    // A playlist item's own metadata (title, duration, not live) would be
    // replaced by the station's live item until the next item starts.
    if (_playlistMode) return;
    final station = currentStation.valueOrNull;
    if (station == null || mediaItem.valueOrNull == null) return;
    final item = _buildStationMediaItem(station);
    _lastEmittedSongId = -1; // force re-evaluation on next poll
    final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
    mediaItem.add(item.copyWith(rating: Rating.newHeartRating(isFav)));
  }

  /// For HLS streams with retained segments, seeks behind the live edge
  /// so the buffer fills instantly at network speed. The offset is controlled
  /// by SeekModeManager (Instant / 2 min / 4 min). Applied on both WiFi
  /// and mobile data for resilience during network transitions (e.g. leaving
  /// WiFi range when connecting to CarPlay).
  ///
  /// Non-blocking: fires the seek without awaiting so player.play() can
  /// start immediately. Both AVFoundation and ExoPlayer correctly play
  /// from the seek target when play() overlaps an in-progress seek.
  ///
  /// Skipped after loading a start variant, which already begins there
  /// (see [HlsStartVariant.followUp]).
  void _seekBehindLiveEdge() {
    final offset = SeekModeManager.currentOffset;
    if (offset == Duration.zero) {
      _stayAtLiveEdge('instant mode');
      return;
    }
    final duration = player.duration;
    if (duration == null || duration.inSeconds < 10) {
      _trace('_seekBehindLiveEdge: no duration or too short ($duration), skipping');
      return;
    }
    // Clamp the offset so the playhead never lands closer than
    // _dvrTrailingSafetyMargin to the window's trailing (oldest) edge. Without
    // this a 5-min offset on a window only ~6 min deep would anchor within
    // seconds of the edge — the segment is evicted almost immediately, leaving
    // no forward runway and defeating the point of seeking back.
    final maxOffset = duration - _dvrTrailingSafetyMargin;
    if (maxOffset <= Duration.zero) {
      // Window shallower than our safety margin — any back-seek lands at/before
      // the trailing edge. Stay near the live edge instead.
      _stayAtLiveEdge('window ($duration) too shallow for a safe offset');
      return;
    }
    final effectiveOffset = offset > maxOffset ? maxOffset : offset;
    final seekTarget = duration - effectiveOffset;
    _trace('_seekBehindLiveEdge: duration=$duration, offset=$offset, effectiveOffset=$effectiveOffset, seeking to $seekTarget');
    player.seek(seekTarget).catchError((e) {
      _trace('_seekBehindLiveEdge: seek failed ($e), continuing from live edge');
    });
  }

  /// Keeps a fresh live load at the live point, where it starts anyway.
  ///
  /// On Darwin a reload while playing (offset change, liveness recovery)
  /// leaves the new item at rate 0: just_audio's `play()` is a no-op while
  /// `playing`, and only a seek completion re-applies the rate. Without the
  /// seek AVPlayer buffers until full and never advances, silent while it
  /// reports playing (measured on the iOS simulator), so it seeks to the
  /// live point there instead of skipping.
  void _stayAtLiveEdge(String reason) {
    final duration = player.duration;
    if (!_reloadNeedsSeekToPlay || duration == null) {
      _trace('_seekBehindLiveEdge: $reason, skipping');
      return;
    }
    _trace('_seekBehindLiveEdge: $reason, reloaded while playing: seeking to '
        'the live point ($duration) so the player resumes');
    player.seek(duration).catchError((e) {
      _trace('_seekBehindLiveEdge: live-point seek failed ($e)');
    });
  }

  /// Restarts a start variant reloaded while playing (see
  /// [_stayAtLiveEdge]) where it begins: a seek to the native position the
  /// load reported, which `#EXT-X-START` put the listening offset behind
  /// live. Non-blocking, like [_seekBehindLiveEdge].
  void _restartWhereLoaded() {
    final start = player.playbackEvent.updatePosition;
    _trace('play: the start variant was reloaded while playing, restarting it '
        'where it begins ($start)');
    player.seek(start).catchError((e) {
      _trace('play: restart seek failed ($e)');
    });
  }

  /// Whether the source just loaded plays only once a seek completes: a
  /// Darwin reload while already playing (see [_stayAtLiveEdge]).
  bool get _reloadNeedsSeekToPlay =>
      ReconnectPolicy.silentStallPossible && player.playing;

  /// Starts or stops the live-HLS liveness watchdog. It runs only while a
  /// local live HLS stream plays on a player that can go silent while still
  /// reporting playing (Darwin), and while the remote kill switch allows it.
  /// Idempotent — safe to call on every playing-state flip.
  void _syncLiveHlsWatchdog() {
    final shouldRun = player.playing &&
        _isLocalLiveHls &&
        _loadedStreamUrl != null &&
        ReconnectPolicy.silentStallPossible &&
        HlsHealthWatchdogFlag.instance.enabled;
    if (!shouldRun) {
      _stopLiveHlsWatchdog();
      return;
    }
    if (_liveHlsWatchdogTimer != null) return;
    _trace('live-hls watchdog: started');
    _liveHlsWatchdogTimer = Timer.periodic(
      ReconnectPolicy.liveHlsWatchdogInterval,
      (_) => _checkLiveHlsHealth(),
    );
  }

  void _stopLiveHlsWatchdog() {
    _liveHlsWatchdogTimer?.cancel();
    _liveHlsWatchdogTimer = null;
    _loadPauses.reset();
  }

  /// Periodic tick: evaluates [ReconnectPolicy.liveHlsStall] and, when a rule
  /// fires, recovers (see [_recoverFromLiveHlsStall]).
  ///
  /// The remote kill switch is re-read on every tick, so turning it off
  /// stops a watchdog that is already running instead of waiting for the
  /// next playing flip (which, in a car, may not come for the whole drive).
  void _checkLiveHlsHealth() {
    if (!HlsHealthWatchdogFlag.instance.enabled) {
      _trace('live-hls watchdog: disabled by the remote flag, stopping');
      _stopLiveHlsWatchdog();
      return;
    }
    // Without internet a reload cannot load anything, and it would throw
    // away the audio still buffered (as much as the 2 or 5 min offset).
    // The player plays on and the network-restored path takes over.
    if (NetworkService.instance.isOffline.value) return;
    final now = DateTime.now();
    final url = _loadedStreamUrl;
    final sample = _hlsTimeline.healthSample(now);
    final stall = ReconnectPolicy.liveHlsStall(
      playing: player.playing,
      processingState: player.processingState,
      hasLiveHlsLoaded: _isLocalLiveHls && url != null,
      isCasting: isCasting,
      isVideoOrPlaylistMode: _videoMode || _playlistMode,
      silentStallPossible: ReconnectPolicy.silentStallPossible,
      now: now,
      s: sample,
    );
    if (url == null) return;
    if (stall == LiveHlsStall.none) {
      _noteLiveHlsLoadPause(sample, now);
      return;
    }
    _recoverFromLiveHlsStall(stall, url, sample, now);
  }

  /// Logs the load pauses the watchdog rides out, when they start and when
  /// the player loads again (see [LiveHlsLoadPauses]).
  void _noteLiveHlsLoadPause(LiveHlsHealthSample s, DateTime now) {
    final e = _loadPauses.tick(s, now,
        playing: player.playing &&
            player.processingState == ProcessingState.ready);
    if (e == null) return;
    final ahead = e.bufferedAheadSeconds;
    final slug = currentStation.valueOrNull?.slug ?? '';
    if (e.resumed) {
      _log('live-hls watchdog: loading again after ${e.seconds}s, '
          '${ahead?.toStringAsFixed(1)}s were left');
      AnalyticsService.instance.logDebug('stream hls load resumed', {
        'station_slug': slug,
        'paused_s': e.seconds,
        'buffered_ahead_s': ahead,
      });
      return;
    }
    _log('live-hls watchdog: no load for ${e.seconds}s, '
        '${ahead?.toStringAsFixed(1)}s still buffered, waiting');
    AnalyticsService.instance.logDebug('stream hls load pause', {
      'station_slug': slug,
      'stagnant_s': e.seconds,
      'buffered_ahead_s': ahead,
      'playhead_lag_s': s.edgeLagSeconds,
    });
  }

  /// Reloads after a liveness fire, failing the stream over only on a
  /// repeat fire (see [LiveHlsStallRecovery]).
  ///
  /// The watchdog keeps running through the reload: while the load is in
  /// flight there is no loaded URL (the check is a no-op), and the new
  /// load restarts the grace period. `play()` re-syncs it once the new
  /// source is loaded, which is what lets a second fire escalate.
  void _recoverFromLiveHlsStall(
    LiveHlsStall stall,
    String url,
    LiveHlsHealthSample sample,
    DateTime now,
  ) {
    final action = _liveHlsRecovery.decide(
      stall: stall,
      url: url,
      station: currentStation.valueOrNull?.slug ?? '',
      offset: SeekModeManager.currentOffset,
      now: now,
    );
    if (action == LiveHlsRecoveryAction.none) return;
    _reportLiveHlsStall(stall, action, sample, now);
    if (stall == LiveHlsStall.starving) _recordStreamTrouble('hls_starving');
    if (action == LiveHlsRecoveryAction.failOverAndReload) {
      _recordStreamFailure(url, now);
    }
    // Clear the loaded URL so play() takes the fresh-load path (which
    // re-seeks behind the live edge and re-anchors the timeline).
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    play();
  }

  /// Test seam: runs the recovery for [stall] as if the watchdog tick at
  /// [now] had detected it on the loaded stream. The rules themselves are
  /// covered by the pure [ReconnectPolicy.liveHlsStall] tests and the
  /// recorded-run replays; this drives the handler wiring around them.
  @visibleForTesting
  void debugRecoverFromLiveHlsStall(LiveHlsStall stall, DateTime now) {
    final url = _loadedStreamUrl;
    if (url == null || stall == LiveHlsStall.none) return;
    _recoverFromLiveHlsStall(stall, url, _hlsTimeline.healthSample(now), now);
  }

  /// Whether the live-HLS liveness watchdog timer is armed.
  @visibleForTesting
  bool get isLiveHlsWatchdogRunning => _liveHlsWatchdogTimer != null;

  /// Log line, diagnostic ring entry and a `stream hls stalled` PostHog Logs
  /// record for a liveness fire.
  void _reportLiveHlsStall(
    LiveHlsStall stall,
    LiveHlsRecoveryAction action,
    LiveHlsHealthSample s,
    DateTime now,
  ) {
    double? since(DateTime? t) =>
        t == null ? null : now.difference(t).inMilliseconds / 1000;
    double? secs(Duration? d) => d == null ? null : d.inMilliseconds / 1000;
    final audible = _audibleInstant();
    final verb = action == LiveHlsRecoveryAction.failOverAndReload
        ? 'failing over'
        : 'reloading';
    final edgeLag = s.edgeLagSeconds?.toStringAsFixed(1);
    _log('live-hls watchdog: ${stall.name} — $verb '
        '(edgeLag=${edgeLag}s originStale=${secs(s.originStaleFor)}s '
        'unreachable=${secs(s.originUnreachableFor)}s '
        'bufferStagnant=${since(s.bufferedChangedAt)}s '
        'bufferedAhead=${s.bufferedAheadSeconds?.toStringAsFixed(1)}s)');
    _recordStreamEvent(
      StreamEventKind.hlsStalled,
      'HLS silent (${stall.name}) — $verb',
    );
    final lastInfo = currentStreamInfo.valueOrNull;
    AnalyticsService.instance.logWarning('stream hls stalled', {
      'station_slug':
          lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
      'station_id': currentStation.valueOrNull?.id,
      'stream_url': lastInfo?.url,
      'stream_type': lastInfo?.type,
      'stream_index': lastInfo?.attemptIndex,
      'total_streams': lastInfo?.totalStreams,
      'reason': stall.name,
      'action': action.name,
      'playhead_lag_s': s.edgeLagSeconds,
      'latency_s': since(audible),
      'origin_stale_s': since(s.originAdvancedAt),
      'origin_unreachable_s': secs(s.originUnreachableFor),
      'buffer_stagnant_s': since(s.bufferedChangedAt),
      'buffered_ahead_s': s.bufferedAheadSeconds,
      'anchor_quality': _hlsTimeline.anchorQuality?.name,
    });
  }

  // ── Live HLS after an outage (Darwin) ──────────────────────────────────

  /// Notes the outage starting now for the check once the internet is back
  /// (see [_scheduleOutageLoadCheck]): the live HLS load playing and what
  /// it had buffered. A check still pending belongs to this outage too, the
  /// network having dropped again before it ran: it waits for the next
  /// restore, counting from the first loss.
  void _noteOutageStart() {
    _outageLoadCheck?.cancel();
    _outageSince ??= DateTime.now();
    _outageHlsGeneration =
        _isLocalLiveHls && _loadedStreamUrl != null ? _hlsLoadGeneration : null;
    _outageBufferedPosition = player.bufferedPosition;
    _outageLoadResumedAt = null;
  }

  /// Notes when the load the outage check follows first loads more, for its
  /// log: how long after the internet came back the player resumed.
  void _noteLoadAfterOutage(Duration bufferedPosition) {
    if (_outageSince == null || _outageLoadResumedAt != null) return;
    if (_outageHlsGeneration != _hlsLoadGeneration) return;
    if (bufferedPosition > _outageBufferedPosition) {
      _outageLoadResumedAt = DateTime.now();
    }
  }

  /// Once the internet answered again at [restoredAt], checks that the live
  /// HLS stream still playing from its buffer loads again, when the outage
  /// lasted long enough for AVPlayer to stop retrying (see
  /// [ReconnectPolicy.outageCheckAfter]).
  void _scheduleOutageLoadCheck(DateTime restoredAt) {
    final since = _outageSince;
    if (since == null) return;
    final ahead = _hlsTimeline.bufferedAheadSeconds(DateTime.now());
    final delay = _outageCheckApplies
        ? ReconnectPolicy.outageCheckDelay(
            outage: restoredAt.difference(since),
            bufferedAhead: ahead == null
                ? null
                : Duration(milliseconds: (ahead * 1000).round()),
          )
        : null;
    if (delay == null) {
      _outageSince = null;
      return;
    }
    _outageLoadCheck?.cancel();
    _outageLoadCheck =
        Timer(delay, () => _checkLoadingAfterOutage(since, restoredAt));
  }

  /// Whether the live HLS load that played when the internet was lost
  /// still plays from its buffer, on the player that stops retrying
  /// (AVPlayer), with the liveness kill switch on.
  bool get _outageCheckApplies =>
      ReconnectPolicy.silentStallPossible &&
      HlsHealthWatchdogFlag.instance.enabled &&
      _isLocalLiveHls &&
      _loadedStreamUrl != null &&
      _outageHlsGeneration == _hlsLoadGeneration &&
      player.playing &&
      player.processingState == ProcessingState.ready;

  /// Reloads the live HLS stream when its player loaded nothing since the
  /// outage that began at [since]: it would play its buffer out, then
  /// restart at the live point (see [ReconnectPolicy.outageCheckAfter]).
  /// The outage kept the listening offset, so the reload, which starts
  /// there again, goes on about where the audio was.
  void _checkLoadingAfterOutage(DateTime since, DateTime restoredAt) {
    _outageSince = null;
    if (!_outageCheckApplies || NetworkService.instance.isOffline.value) {
      return;
    }
    final now = DateTime.now();
    final s = _hlsTimeline.healthSample(now);
    final loaded = player.bufferedPosition - _outageBufferedPosition;
    final outage = restoredAt.difference(since);
    double? afterRestore(DateTime? t) =>
        t == null ? null : t.difference(restoredAt).inMilliseconds / 1000;
    final props = <String, Object?>{
      'station_slug': currentStation.valueOrNull?.slug ?? '',
      'station_id': currentStation.valueOrNull?.id,
      'stream_url': _loadedStreamUrl,
      'outage_s': outage.inMilliseconds / 1000,
      'since_restore_s': afterRestore(now),
      'resumed_after_restore_s': afterRestore(_outageLoadResumedAt),
      'loaded_s': loaded.inMilliseconds / 1000,
      'buffered_ahead_s': s.bufferedAheadSeconds,
      'playhead_lag_s': s.edgeLagSeconds,
    };
    final ahead = s.bufferedAheadSeconds?.toStringAsFixed(1);
    if (loaded > Duration.zero) {
      _log('after a ${outage.inSeconds}s outage the player loads again '
          '(${loaded.inSeconds}s loaded, bufferedAhead=${ahead}s)');
      AnalyticsService.instance
          .logDebug('stream hls loading after outage', props);
      return;
    }
    _log('after a ${outage.inSeconds}s outage the player loaded nothing, '
        'reloading at the listening offset (bufferedAhead=${ahead}s)');
    _recordStreamEvent(
      StreamEventKind.hlsStalled,
      'HLS not loading after a ${outage.inSeconds}s outage — reloading',
    );
    AnalyticsService.instance.logWarning('stream hls stuck after outage', props);
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    play();
  }

  /// Test seam: runs the outage check for a live HLS stream whose internet
  /// was lost at [since] and answered again at [restoredAt], at once.
  @visibleForTesting
  void debugCheckLoadingAfterOutage(DateTime since, DateTime restoredAt) =>
      _checkLoadingAfterOutage(since, restoredAt);

  /// Records a stream-trouble event and, once enough accumulate within
  /// [_slowConnectionWindow], escalates the seek offset to 5 minutes so the
  /// player keeps a large forward buffer on a slow/flaky link. Sticky for the
  /// session (see [SeekModeManager.changeAutoSlowConnection]).
  void _recordStreamTrouble(String cause) {
    final now = DateTime.now();
    _streamTroubleEvents.add(now);
    _streamTroubleEvents
        .removeWhere((t) => now.difference(t) > _slowConnectionWindow);
    if (SeekModeManager.isAutoSlowConnection) return;
    if (_streamTroubleEvents.length < _slowConnectionTroubleThreshold) return;
    _log('slow-connection escalation: ${_streamTroubleEvents.length} stream '
        'trouble events within ${_slowConnectionWindow.inMinutes}min '
        '($cause) — raising seek offset to 5 minutes for subsequent loads');
    SeekModeManager.changeAutoSlowConnection(true);
    AnalyticsService.instance.log('seek offset escalated', {
      'reason': cause,
      'trouble_count': _streamTroubleEvents.length,
      'window_minutes': _slowConnectionWindow.inMinutes,
    });
  }

  // ── Live HLS timeline: playlist poll, anchoring, song boundaries ───────

  /// Playlist poll cadence. nginx serves the playlist as a static file, so a
  /// fetch every 10 s costs nothing; it keeps the skew estimate, the origin
  /// progress and the announced song boundaries fresh.
  static const _hlsPlaylistRefreshInterval = Duration(seconds: 10);

  static const _hlsPollTimeout = Duration(seconds: 5);

  /// Anchor re-checks, from the start of a playing && ready run: a tick
  /// right after [HlsPlayheadClock.settle] (ExoPlayer reports once, ~0.1 s
  /// after ready, then nothing), snapshot retries 1, 2 and 4 s apart when
  /// no snapshot matches the report, and the projection deadline.
  static const List<Duration> _hlsAnchorCheckpoints = [
    Duration(milliseconds: 1100),
    Duration(milliseconds: 3100),
    Duration(milliseconds: 7100),
    Duration(milliseconds: 10100),
  ];

  /// Starts a new load generation: forgets the previous stream's clock,
  /// boundaries and timers. Returns the new generation.
  int _beginHlsLoad() {
    _hlsPlaylistPollTimer?.cancel();
    _hlsPlaylistPollTimer = null;
    _cancelSongBoundaryTimer();
    _cancelHlsAnchorChecks();
    _hlsTimeline.beginLoad(DateTime.now());
    _loadPauses.reset();
    _songBoundaries.clear();
    _lastMetadataChangedAt = null;
    return ++_hlsLoadGeneration;
  }

  /// Server wall-clock instant of the audio the listener hears (or would
  /// hear on resume). Null when no local live HLS is loaded, or while the
  /// timeline anchors (an anchored refresh follows automatically).
  DateTime? _audibleInstant() {
    if (!_isLocalLiveHls) return null;
    final now = DateTime.now();
    if (HlsTimeline.isSupportedPlatform &&
        !_hlsTimeline.lacksProgramDateTime) {
      return _hlsTimeline.audibleInstant(now);
    }
    // Documented approximation for Windows/Linux (mpv live-HLS positions
    // are unvalidated) and playlists without PROGRAM-DATE-TIME. Frozen
    // while not playing, like the real clock. Neither starts from a start
    // variant: Windows/Linux load none, and the origin, the only host that
    // publishes them, stamps PROGRAM-DATE-TIME.
    final heardAt = player.playing ? now : (_stoppedPlayingAt ?? now);
    return heardAt.subtract(HlsTimeline.approximateLatency(
      SeekModeManager.currentOffset,
      darwin: Platform.isIOS || Platform.isMacOS,
      startVariant: false,
    ));
  }

  /// Feeds a player event to the timeline, then reacts to an anchor or to
  /// playback starting/stopping to advance.
  void _onPlayerEventForTimeline(PlaybackEvent e) {
    if (!_isLocalLiveHls || !HlsTimeline.isSupportedPlatform) return;
    final wasAdvancing = _hlsTimeline.isAdvancing;
    _hlsTimeline.onPlayerEvent(
      playing: player.playing,
      ready: e.processingState == ProcessingState.ready,
      updatePosition: e.updatePosition,
      updateTime: e.updateTime,
      bufferedPosition: e.bufferedPosition,
      now: DateTime.now(),
    );
    if (_hlsTimeline.takeJustAnchored()) {
      _onHlsTimelineAnchored();
    } else if (_hlsTimeline.isAdvancing != wasAdvancing) {
      _planSongBoundaries();
    }
    _armHlsAnchorChecks();
  }

  /// Schedules the anchor re-checks for the current playing && ready run
  /// while the clock is not exactly anchored. Idempotent per run.
  void _armHlsAnchorChecks() {
    final runStart = _hlsTimeline.advancingSince;
    if (runStart == null ||
        _hlsTimeline.isExactlyAnchored ||
        _hlsTimeline.lacksProgramDateTime) {
      _cancelHlsAnchorChecks();
      return;
    }
    if (_hlsAnchorRunStart == runStart) return;
    _cancelHlsAnchorChecks();
    _hlsAnchorRunStart = runStart;
    _scheduleHlsAnchorCheck(_hlsLoadGeneration);
  }

  void _scheduleHlsAnchorCheck(int generation) {
    final runStart = _hlsAnchorRunStart;
    if (runStart == null ||
        _hlsAnchorCheckIndex >= _hlsAnchorCheckpoints.length) {
      return;
    }
    final due = runStart.add(_hlsAnchorCheckpoints[_hlsAnchorCheckIndex]);
    final delay = due.difference(DateTime.now());
    _hlsAnchorTimer = Timer(delay.isNegative ? Duration.zero : delay,
        () => _runHlsAnchorCheck(generation, runStart));
  }

  void _runHlsAnchorCheck(int generation, DateTime runStart) {
    if (generation != _hlsLoadGeneration ||
        _hlsTimeline.advancingSince != runStart) {
      return;
    }
    final now = DateTime.now();
    _hlsTimeline.tick(now);
    if (_hlsTimeline.takeJustAnchored()) _onHlsTimelineAnchored();
    if (_hlsTimeline.isExactlyAnchored) return;
    final isLast = _hlsAnchorCheckIndex == _hlsAnchorCheckpoints.length - 1;
    if (!isLast && _hlsTimeline.needsAnchorSnapshot(now)) {
      _trace('hls-timeline: no snapshot matches the native position, '
          'refetching the playlist');
      unawaited(_pollHlsPlaylist(generation: generation));
    }
    _hlsAnchorCheckIndex++;
    _scheduleHlsAnchorCheck(generation);
  }

  void _cancelHlsAnchorChecks() {
    _hlsAnchorTimer?.cancel();
    _hlsAnchorTimer = null;
    _hlsAnchorRunStart = null;
    _hlsAnchorCheckIndex = 0;
  }

  /// The clock (re)anchored: drop boundaries already heard, issue the
  /// anchored refresh (station start, offset change, reconnect, stale
  /// resume) and plan the next boundary.
  void _onHlsTimelineAnchored() {
    final now = DateTime.now();
    final audible = _audibleInstant();
    final pdt = _hlsTimeline.playheadPdt(now);
    final latency = audible == null
        ? null
        : now.difference(audible).inMilliseconds / 1000;
    final gap = _hlsTimeline.anchorSnapshotGap;
    _log('hls-timeline: anchored '
        'playheadPdt=${pdt == null ? '-' : _isoFromSeconds(pdt)} '
        'skew=${_hlsTimeline.skewSeconds(now)?.toStringAsFixed(2)} '
        'latency=${latency?.toStringAsFixed(1)}s '
        'anchorQuality=${_hlsTimeline.anchorQuality?.name} '
        'snapshotAge=${gap == null ? '-' : gap.inMilliseconds / 1000}s');
    AnalyticsService.instance.logDebug('hls timeline anchored', {
      'station_slug': currentStation.valueOrNull?.slug,
      'anchor_quality': _hlsTimeline.anchorQuality?.name,
      'latency_s': latency,
      'skew_s': _hlsTimeline.skewSeconds(now),
      'snapshot_age_s': gap == null ? null : gap.inMilliseconds / 1000,
    });
    // Only what is already heard: a boundary within the next 2 s is not
    // the song the anchor resolves, so planning takes it as a change.
    if (audible != null) _songBoundaries.dropHeard(audible);
    unawaited(stationDataService.refreshMetadataNow());
    _planSongBoundaries();
  }

  static String _isoFromSeconds(double seconds) =>
      DateTime.fromMicrosecondsSinceEpoch((seconds * 1e6).round(),
              isUtc: true)
          .toIso8601String();

  /// Fetches the playlist once and feeds the timeline and the boundary
  /// queue. [url]/[generation] default to the loaded stream; a response
  /// that started for a previous load is discarded (station-switch race).
  Future<void> _pollHlsPlaylist({String? url, int? generation}) async {
    final u = url ?? _loadedStreamUrl;
    final gen = generation ?? _hlsLoadGeneration;
    if (u == null) return;
    HlsPlaylistSnapshot? snapshot;
    var withoutPdt = false;
    var answered = false;
    try {
      final r = await _hlsHttp.get(Uri.parse(u)).timeout(_hlsPollTimeout);
      answered = true;
      if (r.statusCode == 200) {
        // HLS playlists are UTF-8 (RFC 8216), but the origin sends no
        // charset, so `r.body` would decode Latin-1 and garble diacritics
        // in the song titles the playlist announces.
        final body = utf8.decode(r.bodyBytes, allowMalformed: true);
        snapshot = HlsPlaylistSnapshot.parse(body,
            fetchedAt: DateTime.now(),
            lastModifiedHeader: r.headers['last-modified']);
        withoutPdt = snapshot == null &&
            HlsPlaylistSnapshot.isMediaPlaylistWithoutPdt(body);
      } else {
        _log('hls poll: HTTP ${r.statusCode}');
      }
    } catch (e) {
      _log('hls poll: $e');
    }
    // Any answer, even an error status, proves the internet works; none
    // makes NetworkService check it. A tunnel changes no network, so this
    // poll is what notices it while the buffer keeps the audio going.
    final network = NetworkService.instance;
    answered ? network.reportRequestSuccess() : network.reportRequestFailure();
    if (!_isCurrentHlsPoll(u, gen)) return;
    final now = DateTime.now();
    if (snapshot != null) {
      _hlsTimeline.onSnapshot(snapshot, now);
    } else if (withoutPdt) {
      _hlsTimeline.onPlaylistWithoutPdt(now);
    } else {
      _hlsTimeline.onPollFailed(now);
      return;
    }
    // Queue this poll's boundaries before handling an anchor it caused:
    // the anchor drops the ones already heard, so none of them is later
    // taken as a change that supersedes the anchored refresh.
    if (snapshot != null) _queueSongBoundaries(snapshot);
    if (_hlsTimeline.takeJustAnchored()) {
      _onHlsTimelineAnchored();
    } else if (snapshot != null) {
      _planSongBoundaries();
    }
  }

  /// Whether a poll for [url] issued in [generation] still belongs to the
  /// loaded stream. Before the load completes, the concurrent fetch is
  /// accepted by generation alone.
  bool _isCurrentHlsPoll(String url, int generation) {
    if (generation != _hlsLoadGeneration) return false;
    final loaded = _loadedStreamUrl;
    return loaded == null || (loaded == url && _loadedStreamType == 'HLS');
  }

  /// Queues the song boundaries a poll announced; the caller re-plans. On
  /// Android TV ([StationDataService.preferLiveMetadata]) the live title
  /// shows, so a new METADATA-CHANGED instant refreshes right away instead.
  void _queueSongBoundaries(HlsPlaylistSnapshot s) {
    if (stationDataService.preferLiveMetadata) {
      final changedAt = s.metadataChangedAt;
      if (changedAt == null || changedAt == _lastMetadataChangedAt) return;
      _lastMetadataChangedAt = changedAt;
      _trace('song-boundary: METADATA-CHANGED '
          '${changedAt.toIso8601String()}, refreshing live (TV)');
      unawaited(stationDataService.refreshMetadataNow(boundary: changedAt));
      return;
    }
    _songBoundaries.add(s.songBoundaries);
  }

  /// Refreshes for the newest boundary the audible instant reached, and
  /// arms one timer for the next. The timer re-evaluates the instant when
  /// it fires, never trusting the delay it was armed with. Suspended while
  /// paused or buffering (the instant is frozen); re-planned on resume.
  void _planSongBoundaries() {
    _cancelSongBoundaryTimer();
    final now = DateTime.now();
    final audible = _audibleInstant();
    final usesTimeline = HlsTimeline.isSupportedPlatform &&
        !_hlsTimeline.lacksProgramDateTime;
    final advancing = usesTimeline
        ? _hlsTimeline.isAdvancing
        : player.playing && player.processingState == ProcessingState.ready;
    if (audible == null || !advancing) return;
    if (_songBoundaries.reopenAfter(audible)) {
      _trace('song-boundary: audible instant moved back, re-syncing');
      unawaited(stationDataService.refreshMetadataNow());
    }
    final due = _songBoundaries.takeReached(audible);
    if (due != null) {
      _trace('song-boundary: reached ${due.at.toIso8601String()} '
          '(audible ${audible.toIso8601String()})');
      unawaited(stationDataService.refreshMetadataNow(
          boundary: due.at, hint: due.hint));
    }
    final delay = _songBoundaries.delayUntilNext(audible, now);
    if (delay != null) _songBoundaryTimer = Timer(delay, _planSongBoundaries);
  }

  void _cancelSongBoundaryTimer() {
    _songBoundaryTimer?.cancel();
    _songBoundaryTimer = null;
  }

  /// Starts the periodic playlist poll ([_hlsPlaylistRefreshInterval]).
  /// [skipInitialFetch] when a fetch for this load is already in flight.
  void _startHlsPlaylistPoll({bool skipInitialFetch = false}) {
    _hlsPlaylistPollTimer?.cancel();
    if (!skipInitialFetch) unawaited(_pollHlsPlaylist());
    _hlsPlaylistPollTimer = Timer.periodic(
      _hlsPlaylistRefreshInterval,
      (_) => unawaited(_pollHlsPlaylist()),
    );
  }

  /// Stops the poll and every timeline timer, and forgets the timeline. A
  /// response still in flight is discarded (generation bump).
  ///
  /// [endAlignedPlayback]: the listener left time-shifted playback for good
  /// (station switch, stop, error, non-HLS load, cast). False only for the
  /// 60 s pause disconnect, so the paused title stays until resume.
  void _stopHlsPlaylistRefresh({bool endAlignedPlayback = true}) {
    _hlsPlaylistPollTimer?.cancel();
    _hlsPlaylistPollTimer = null;
    _cancelSongBoundaryTimer();
    _cancelHlsAnchorChecks();
    _hlsLoadGeneration++;
    _hlsTimeline.reset();
    _songBoundaries.clear();
    _lastMetadataChangedAt = null;
    if (endAlignedPlayback) stationDataService.onAlignedPlaybackEnded();
  }

  /// Subscribes to Cast sessions (the service registers after the first
  /// frame). Casting stops the local player, so a rising edge ends the
  /// local time-shifted session. Idempotent.
  ///
  /// A falling edge (disconnect) leaves the local player stopped by design
  /// (main.dart), so it clears the play intent: otherwise the next
  /// foreground or network restore would start the phone's speaker.
  ///
  /// Either edge changes the listening delay (the receiver plays live).
  void watchCastSessions(CastService castService) {
    if (_castSessionSub != null) return;
    var wasCasting = false;
    _castSessionSub = castService.isCasting.distinct().listen((casting) {
      if (casting) {
        _stopHlsPlaylistRefresh();
      } else if (wasCasting) {
        _hasBeenPlayed = false;
      }
      if (casting != wasCasting) stationDataService.onListeningDelayChanged();
      wasCasting = casting;
    });
  }

  // ── Fast-start measurement ────────────────────────────────────────────

  /// Starts the tap→first-audio stopwatch for [station]. Debug-only.
  void _beginFastStartMeasure(Station station) {
    if (!kDebugMode) return;
    _fastStartLabel = station.isTv
        ? 'TV'
        : (station.stationType == StationMediaType.playlist
            ? 'PLAYLIST'
            : 'AUDIO');
    _fastStartWatch = Stopwatch()..start();
    _fastStartDone = false;
  }

  /// Reads the stopwatch on the first position advance while playing and logs
  /// the tap→first-audio latency, labelled by resolved stream type. Debug-only.
  void _maybeCompleteFastStartMeasure() {
    if (_fastStartDone) return;
    final watch = _fastStartWatch;
    if (watch == null) return;
    if (!player.playing || player.position <= Duration.zero) return;
    _fastStartDone = true;
    watch.stop();
    final ms = watch.elapsedMilliseconds;
    final type = _loadedStreamType ?? _fastStartLabel ?? '?';
    // Labelled so it can be grepped from device logs when measuring.
    debugPrint('[FASTSTART] tap→first-audio ${ms}ms '
        '(kind=$_fastStartLabel stream=$type '
        'station=${currentStation.valueOrNull?.slug})');
    AnalyticsService.instance.captureDebug('fast_start_first_audio', {
      'ms': ms,
      'kind': _fastStartLabel,
      'stream_type': type,
      'station_slug': currentStation.valueOrNull?.slug,
      'station_id': currentStation.valueOrNull?.id,
    });
  }

  // ── Connection pre-warm ───────────────────────────────────────────────

  /// Warms the network path to the last-played station's stream so the first
  /// tap of the session starts faster (DNS + TLS + first bytes already primed).
  ///
  /// Fire-and-forget and startup-safe: guarded to run once, waits for the
  /// station list off the UI thread, never blocks, and swallows all errors.
  /// Warms exactly one station — reuses the HLS playlist GET for HLS streams,
  /// a HEAD for direct/MP3 streams.
  Future<void> prewarmLastPlayed() async {
    if (_prewarmed) return;
    _prewarmed = true;
    try {
      final slug = _prefs.getString(LAST_PLAYED_MEDIA_ITEM);
      if (slug == null) return;
      // Resolve the station once the list is available (bounded wait so we
      // never leak a subscription if stations never load).
      Station? station = _firstBySlug(stationDataService.stations.value, slug);
      station ??= await stationDataService.stations.stream
          .firstWhere((list) => list.isNotEmpty)
          .then((list) => _firstBySlug(list, slug))
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
      if (station == null) return;
      final streams = Utils.getStationStreamObjects(station.rawStationData);
      if (streams.isEmpty) return;
      final first = streams.first;
      final url = first['url'];
      if (url == null || url.isEmpty) return;
      final uri = Uri.parse(url);
      final isHls = first['type'] == 'HLS';
      if (isHls) {
        // Reuses the lightweight playlist GET — primes DNS/TLS and the CDN
        // edge, on the client whose pooled connection the first poll uses,
        // and, for a load through the hold proxy, on the proxy's upstream
        // client, whose connection the player's first request then reuses.
        final holdProxy = _holdProxyFor(url, isHls: true);
        await Future.wait([
          _hlsHttp.get(uri).timeout(const Duration(seconds: 5)),
          if (holdProxy != null)
            holdProxy.start().then((_) => holdProxy.prewarm(url)),
        ]);
      } else {
        await http.head(uri).timeout(const Duration(seconds: 5));
      }
      _trace('prewarm: warmed ${station.slug} (${isHls ? 'HLS' : 'direct'} $url)');
    } catch (e) {
      _trace('prewarm: $e');
    }
  }

  Station? _firstBySlug(List<Station> list, String slug) {
    for (final s in list) {
      if (s.slug == slug) return s;
    }
    return null;
  }

  // ── Silence keep-alive (iOS-only background-suspension prevention) ──

  /// Schedule the silence keeper to start playing after
  /// [_silenceKeepAliveDelay] of continuous buffering. No-op on Android
  /// where audio_service runs as a foreground service and the engine is
  /// not suspended on stall.
  void _scheduleSilenceKeepAlive() {
    if (!Platform.isIOS) return;
    _silenceKeepAliveStartTimer?.cancel();
    _silenceKeepAliveStartTimer = Timer(_silenceKeepAliveDelay, () async {
      // Re-check the state — buffering may have ended during the delay.
      if (player.processingState != ProcessingState.buffering) return;
      if (!player.playing) return;
      await _startSilenceKeepAlive();
    });
  }

  /// Completes once the keeper's audio is loaded and asked to play, never
  /// when the silence ends, so the video handoffs can await it.
  Future<void> _startSilenceKeepAlive() => _silenceKeeper.start();

  void _stopSilenceKeepAlive() {
    _silenceKeepAliveStartTimer?.cancel();
    _silenceKeepAliveStartTimer = null;
    _silenceKeeper.stop();
  }

  // ── Video mode (media_kit) ────────────────────────────────────────────

  /// Switches playback to media_kit video mode: stops just_audio and opens
  /// [url] on the video player, which becomes the single audio+video source.
  /// [live] marks a TV stream (no VOD timeline); [startPosition] carries a VOD
  /// position across a background handoff. The iOS silence keep-alive covers
  /// the swap so the app isn't suspended mid-handoff.
  Future<void> _enterVideoMode(
    String url, {
    required bool live,
    Duration? startPosition,
  }) async {
    _trace('enterVideoMode($url, live=$live)');
    if (Platform.isIOS) {
      await _startSilenceKeepAlive();
    }
    _disconnectTimer?.cancel();
    _bufferingStallTimer?.cancel();
    _stopHlsPlaylistRefresh();
    if (player.playing || player.processingState != ProcessingState.idle) {
      await player.stop();
    }
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    _videoMode = true;
    isVideoMode.add(true);
    // media_kit autoplays what it opens, so a playing video always carries
    // the play intent (the background handoff acts on it) and a listening
    // session. Set only once video mode owns playback: a reconnect check
    // that runs during the awaits above would otherwise load just_audio
    // next to the video instead of resuming it.
    _hasBeenPlayed = true;
    final station = currentStation.valueOrNull;
    if (station != null) {
      AnalyticsService.instance
          .ensureListening(station.slug, station.title, stationId: station.id);
    }
    // Fresh video content — clear any prior fallback state and re-arm the
    // watchdog so this attempt gets a clean chance to render.
    audioOnlyFallback.add(false);
    _ensureVideoSubscriptions();
    _attachRouteHandoffListeners();
    _startVideoFallbackWatchdog(url, live: live, startPosition: startPosition);
    try {
      await videoService.open(url, live: live, startPosition: startPosition);
    } catch (e) {
      _trace('enterVideoMode: open failed: $e');
      // A synchronous open failure is a hard failure — fall back immediately.
      unawaited(_triggerVideoFallback(url,
          live: live, startPosition: startPosition, reason: 'open_failed'));
    }
    _stopSilenceKeepAlive();
    _broadcastState(player.playbackEvent);
  }

  /// Arms the video→audio fallback for the media just opened in video mode.
  ///
  /// Falls back when the decoder produces no first frame within
  /// [_videoFallbackTimeout], or after [_videoFallbackMaxErrors] player errors
  /// (whichever comes first). Cancels itself the moment a first frame renders
  /// (success) or video mode is left (e.g. a legitimate background handoff), so
  /// it never fights the existing handoff logic.
  void _startVideoFallbackWatchdog(
    String url, {
    required bool live,
    Duration? startPosition,
  }) {
    _cancelVideoFallbackWatchdog();
    _videoFallbackErrorCount = 0;
    final vs = videoService;
    if (vs.hasRenderedFrame) return; // already good (reused warm texture)

    _videoFallbackSubs.add(vs.hasFrameStream.listen((has) {
      if (has) {
        _trace('video first frame rendered → cancel fallback watchdog');
        _cancelVideoFallbackWatchdog();
      }
    }));
    _videoFallbackSubs.add(vs.errorStream.listen((e) {
      if (!_videoMode) return;
      _videoFallbackErrorCount++;
      // Bounded: repeated errors fall back to audio below.
      _trace('video error #$_videoFallbackErrorCount (hasFrame=${vs.hasRenderedFrame}): $e');
      if (!vs.hasRenderedFrame) {
        // Errored before ever showing a picture — the pipeline can't start on
        // this device/codec. Fall back to audio immediately (don't wait out
        // the timeout).
        unawaited(_triggerVideoFallback(url,
            live: live, startPosition: startPosition, reason: 'error_pre_frame'));
      } else if (_videoFallbackErrorCount >= _videoFallbackMaxErrors) {
        // Repeated errors after playback had started — tolerate one blip, then
        // fall back rather than stutter forever.
        unawaited(_triggerVideoFallback(url,
            live: live, startPosition: startPosition, reason: 'repeated_errors'));
      }
    }));
    _videoFallbackTimer = Timer(_videoFallbackTimeout, () {
      if (_videoMode && !vs.hasRenderedFrame) {
        unawaited(_triggerVideoFallback(url,
            live: live, startPosition: startPosition, reason: 'timeout'));
      }
    });
  }

  void _cancelVideoFallbackWatchdog() {
    _videoFallbackTimer?.cancel();
    _videoFallbackTimer = null;
    for (final s in _videoFallbackSubs) {
      s.cancel();
    }
    _videoFallbackSubs.clear();
  }

  /// Hands the current (failing) video content off to the just_audio audio-only
  /// pipeline and surfaces the "Doar audio" chip. Reuses the same audio path as
  /// the background→audio handoff so the two never conflict. Records [url] as
  /// fallen-back so a later foreground/resume doesn't re-attempt video for it.
  Future<void> _triggerVideoFallback(
    String url, {
    required bool live,
    Duration? startPosition,
    required String reason,
  }) async {
    if (!_videoMode) return; // already left video mode (handoff/stop won)
    if (_fallenBackUrl == url) return; // already fell back for this content
    _cancelVideoFallbackWatchdog();
    _log('video→audio fallback ($reason) for $url');
    _fallenBackUrl = url;
    AnalyticsService.instance.logWarning('video fallback to audio', {
      'reason': reason,
      'url': url,
      'live': live,
      'is_playlist': _playlistMode,
      'station_slug': currentStation.valueOrNull?.slug,
    });
    // Carry the current picture position into the audio pipeline for VOD.
    final pos = live ? null : (startPosition ?? videoService.position);
    audioOnlyFallback.add(true);
    if (_playlistMode) {
      await _playlistController.fallbackCurrentVideoToAudio(startPosition: pos);
    } else {
      // TV station: exit video and play audio-only via the standard path.
      await _exitVideoMode(stopVideo: true);
      _loadedStreamUrl = null;
      _loadedStreamType = null;
      await play();
    }
  }

  /// Leaves video mode. When [stopVideo] is true the media_kit player is
  /// stopped (keeps the texture alive for reuse).
  Future<void> _exitVideoMode({required bool stopVideo}) async {
    // Leaving video mode (for any reason) disarms the fallback watchdog so it
    // can never fire against content we're no longer showing.
    _cancelVideoFallbackWatchdog();
    if (!_videoMode) {
      if (stopVideo && videoService.isInitialized) {
        await videoService.stop();
      }
      return;
    }
    _trace('exitVideoMode(stopVideo=$stopVideo)');
    _videoMode = false;
    isVideoMode.add(false);
    if (stopVideo) {
      await videoService.stop();
    }
  }

  /// Subscribes once to the media_kit player's streams so its playing/buffering
  /// /position changes re-broadcast the notification & lock-screen state.
  void _ensureVideoSubscriptions() {
    if (_videoSubs.isNotEmpty) return;
    final vs = videoService;
    _videoSubs.add(
        vs.playingStream.listen((_) => _broadcastState(player.playbackEvent)));
    _videoSubs.add(
        vs.bufferingStream.listen((_) => _broadcastState(player.playbackEvent)));
    // media_kit reports position about once per frame. Clients extrapolate
    // from updateTime, so whole seconds are enough, and spare the platform
    // channels, Android Auto and full-page rebuilds a per-frame broadcast.
    // seek() broadcasts its discontinuity itself.
    _videoSubs.add(vs.positionStream
        .map((p) => p.inSeconds)
        .distinct()
        .listen((_) {
      if (_videoMode) _broadcastState(player.playbackEvent);
    }));
  }

  /// Attaches (once) listeners that force a video→audio handoff when a car or
  /// Cast route connects mid-video-mode (they can't render inline video).
  void _attachRouteHandoffListeners() {
    if (_carRouteSub == null && GetIt.instance.isRegistered<CarPlayService>()) {
      _carRouteSub = GetIt.instance<CarPlayService>()
          .isCarConnected
          .stream
          .listen((connected) {
        if (connected && _videoMode) _handleRouteRequiresAudio();
      });
    }
    if (_castRouteSub == null && GetIt.instance.isRegistered<CastService>()) {
      _castRouteSub =
          GetIt.instance<CastService>().isCasting.stream.listen((casting) {
        if (casting && _videoMode) _handleRouteRequiresAudio();
      });
    }
  }

  /// Car/Cast connected while in video mode — hand off to audio-only.
  void _handleRouteRequiresAudio() {
    _trace('route requires audio (car/cast connected) → handing off');
    if (_playlistMode) {
      unawaited(_playlistController.handleRouteChangeToAudio());
    } else {
      unawaited(_handoffTvVideoToAudio());
    }
  }

  /// TV station: hand off from media_kit video to just_audio audio-only, using
  /// the standard station play() path (live-edge re-tune + metadata).
  Future<void> _handoffTvVideoToAudio() async {
    if (!_videoMode || _tvHandoffInFlight) return;
    // Held only until video mode is left: from then on `_videoMode` guards,
    // and a later handoff (after a foreground round trip) must not be
    // blocked by this one's audio load.
    _tvHandoffInFlight = true;
    try {
      _trace('handoffTvVideoToAudio');
      if (Platform.isIOS) {
        await _startSilenceKeepAlive();
      }
      await _exitVideoMode(stopVideo: true);
    } finally {
      _tvHandoffInFlight = false;
    }
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    await play();
    _stopSilenceKeepAlive();
  }

  /// TV station: hand back from just_audio audio-only to media_kit video mode.
  Future<void> _handoffTvAudioToVideo() async {
    final station = currentStation.valueOrNull;
    if (station == null || !station.isTv) return;
    final url = _primaryStreamUrl(station);
    if (url == null) return;
    // This stream already failed to render video — stay audio-only rather than
    // re-attempting video and fighting the fallback on every resume.
    if (_fallenBackUrl == url) {
      _trace('handoffTvAudioToVideo: skipped (fell back to audio for this url)');
      return;
    }
    _trace('handoffTvAudioToVideo');
    await _enterVideoMode(url, live: true);
  }

  /// Clears the video→audio fallback state so genuinely new content gets a
  /// fresh video attempt (and the "Doar audio" chip is hidden). Called when a
  /// new station or a new playlist item starts.
  void resetVideoFallback() {
    _fallenBackUrl = null;
    if (audioOnlyFallback.value) audioOnlyFallback.add(false);
  }

  // ── Playlist item playback (driven by PlaylistController) ───────────────

  /// Marks a "playlist" station active. See [PlaylistController].
  void enterPlaylistMode() => _playlistMode = true;

  /// Leaves playlist mode.
  void exitPlaylistMode() {
    _playlistMode = false;
    _playlistYoutubeActive = false;
    _youtubePlaying = false;
    _youtubePosition = Duration.zero;
  }

  /// Marks (or clears) that a UI-owned YouTube playlist item is the active
  /// source. While active, [play]/[pause] route to the inline iframe and
  /// `playbackState` reflects it rather than the stopped just_audio player.
  /// Called by [PlaylistController] when a youtube/youtube_playlist item starts.
  void setPlaylistYoutubeActive(bool active, {bool playing = false}) {
    _playlistYoutubeActive = active;
    _youtubePlaying = active && playing;
    if (!active) _youtubePosition = Duration.zero;
    _isConnecting = false;
    _broadcastState(player.playbackEvent);
  }

  /// Feeds the inline YouTube player's real state into `playbackState` so the
  /// mini player, notification and lock screen reflect it. Only broadcasts when
  /// the play/paused flag actually flips (position is stored for the next
  /// broadcast, so a per-tick position report doesn't spam the notification).
  void updateYoutubePlaybackState({bool? playing, Duration? position}) {
    if (!_playlistYoutubeActive) return;
    var changed = false;
    if (playing != null && playing != _youtubePlaying) {
      _youtubePlaying = playing;
      changed = true;
    }
    if (position != null) _youtubePosition = position;
    if (changed) _broadcastState(player.playbackEvent);
  }

  /// Plays a single audio playlist item (VOD) via just_audio. On completion,
  /// [onPlaylistItemCompleted] fires so the controller can advance.
  Future<void> playPlaylistAudioItem(
    String url, {
    Duration? startPosition,
  }) async {
    _trace('playPlaylistAudioItem($url)');
    await _exitVideoMode(stopVideo: true);
    _playlistMode = true;
    _playlistYoutubeActive = false; // an engine-owned source is taking over
    final myOpId = ++_playOperationId;
    _disconnectTimer?.cancel();
    _bufferingStallTimer?.cancel();
    _stopHlsPlaylistRefresh();
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    _isConnecting = true;
    _broadcastState(player.playbackEvent);
    try {
      if (player.playing || player.processingState != ProcessingState.idle) {
        await player.stop();
      }
      await player.setAudioSource(
        AudioSource.uri(Uri.parse(url)),
        preload: true,
      );
      if (myOpId != _playOperationId) return;
      if (startPosition != null && startPosition > Duration.zero) {
        await player.seek(startPosition);
      }
      _isConnecting = false;
      _broadcastState(player.playbackEvent);
      await _playPlayer();
    } catch (e) {
      _isConnecting = false;
      _trace('playPlaylistAudioItem failed: $e');
      onPlaylistItemError?.call(e);
    }
  }

  /// Plays a video playlist item. Uses media_kit video mode when eligible
  /// (foreground, no car/cast), otherwise plays the audio track via just_audio.
  Future<void> playPlaylistVideoItem(
    String url, {
    bool live = false,
    Duration? startPosition,
  }) async {
    _trace('playPlaylistVideoItem($url, live=$live)');
    _playlistMode = true;
    _playlistYoutubeActive = false; // an engine-owned source is taking over
    final useVideo = VideoModeDecision.shouldUseVideoMode(
          isVideoContent: true,
          isForeground: isForeground,
          isCarConnected: isCarConnected,
          isCasting: isCasting,
        ) &&
        _fallenBackUrl != url; // this url already failed to render — audio-only
    if (useVideo) {
      await _enterVideoMode(url, live: live, startPosition: startPosition);
    } else {
      // Audio-only: car/cast/background OR a video that fell back. Keep the
      // "Doar audio" chip visible across a resume for a fallen-back item.
      if (_fallenBackUrl == url) audioOnlyFallback.add(true);
      await playPlaylistAudioItem(
        url,
        startPosition: live ? null : startPosition,
      );
    }
  }

  /// Stops both backends without leaving playlist mode (used between items and
  /// for youtube items, which have no engine-owned player).
  Future<void> stopPlaylistPlayback() async {
    _trace('stopPlaylistPlayback');
    _disconnectTimer?.cancel();
    _bufferingStallTimer?.cancel();
    await _exitVideoMode(stopVideo: true);
    if (player.playing || player.processingState != ProcessingState.idle) {
      await player.stop();
    }
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    _broadcastState(player.playbackEvent);
  }

  /// Updates the notification/lock-screen for a playlist [item] (title,
  /// thumbnail, duration for VOD, `isLive: false`).
  void updatePlaylistMediaItem(
    PlaylistItem item, {
    required int index,
    required int count,
  }) {
    final station = currentStation.valueOrNull;
    Uri? artUri;
    if (item.thumbnailUrl != null && item.thumbnailUrl!.isNotEmpty) {
      artUri = Uri.parse(item.thumbnailUrl!);
    } else {
      final t = station?.rawStationData.thumbnail_url;
      if (t != null && t.isNotEmpty) artUri = Uri.parse(t);
    }
    final dur = (item.durationSeconds != null && item.durationSeconds! > 0)
        ? Duration(seconds: item.durationSeconds!)
        : null;
    mediaItem.add(MediaItem(
      id: item.url,
      title: item.title.isNotEmpty ? item.title : (station?.title ?? ''),
      album: station?.title,
      artist: station?.title,
      displayTitle: item.title,
      displaySubtitle: station?.title,
      artUri: artUri,
      duration: dur,
      isLive: false,
      extras: {
        'station_id': station?.id,
        'station_slug': station?.slug,
        'station_type': 'playlist',
        'playlist_index': index,
        'playlist_count': count,
        'playlist_item_id': item.id,
        'playlist_item_type': item.type.name,
      },
    ));
    _broadcastState(player.playbackEvent);
  }

  /// Public app-lifecycle entry point (wired from HomePage). Updates the
  /// foreground flag and performs the video↔audio handoff for TV stations, or
  /// delegates to [PlaylistController] for playlist stations.
  void onAppLifecycleChanged(AppLifecycleState state) {
    _lifecycleState = state;
    // Back from the background, where iOS may have reclaimed the hold
    // proxy's listening socket: listening again before the player asks.
    final holdProxy = _holdProxy;
    if (state == AppLifecycleState.resumed && holdProxy != null) {
      unawaited(holdProxy.ensureRunning());
    }
    if (_playlistMode) {
      _playlistController.onAppLifecycleChanged(state);
      return;
    }
    final backgrounded = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden;
    if (backgrounded) {
      // A paused TV channel stays paused in video mode: the handoff would
      // start its audio in the background. play() hands off later instead.
      if (_videoMode && _hasBeenPlayed) unawaited(_handoffTvVideoToAudio());
    } else if (state == AppLifecycleState.resumed) {
      final station = currentStation.valueOrNull;
      if (!_videoMode &&
          station != null &&
          station.isTv &&
          VideoModeDecision.shouldUseVideoMode(
            isVideoContent: true,
            isForeground: true,
            isCarConnected: isCarConnected,
            isCasting: isCasting,
          )) {
        unawaited(_handoffTvAudioToVideo());
      }
    }
  }

  /// Stops playback after an error WITHOUT calling super.stop().
  /// This keeps MPRemoteCommandCenter alive so CarPlay/lock-screen
  /// next/prev/play buttons still work and the user can recover.
  Future<void> _stopDueToError() async {
    _trace("_stopDueToError (keeping command center alive)");
    _cancelInFlightPlay();
    _hasBeenPlayed = false;
    _resumeAfterInterruption = false;
    // Otherwise the session keeps counting toward its duration after the stop.
    AnalyticsService.instance.endListening(reason: 'error');
    _disconnectTimer?.cancel();
    _bufferingStallTimer?.cancel();
    _stopLiveHlsWatchdog();
    _stopHlsPlaylistRefresh();
    _bufferingStartedAt = null;
    _stopSilenceKeepAlive();
    unawaited(_pausedStreamTask.end());
    _lastPlayerErrorCode = null;
    _lastPlayerErrorMessage = null;
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    currentStreamInfo.add(null);
    AnalyticsService.instance.setCurrentStream(url: null, type: null, index: null, total: null);
    await player.stop();
    // Broadcast stopped state with controls still available (no super.stop())
    _broadcastState(player.playbackEvent);
  }

  @override
  Future<void> stop() async {
    _trace("stop (isCasting=$isCasting)");
    // Cancels a station switch in flight, like pause().
    _stationSwitchId++;
    _isConnecting = false;
    _resumeAfterInterruption = false;
    if (isCasting) {
      GetIt.instance<CastService>().stop();
      setCastPlaying(false);
      return;
    }
    // Tear down playlist / video mode before the shared cleanup below.
    if (_playlistMode) {
      await _playlistController.stop();
    }
    await _exitVideoMode(stopVideo: true);
    _cancelInFlightPlay();
    _hasBeenPlayed = false;
    AnalyticsService.instance.endListening();
    _disconnectTimer?.cancel();
    _bufferingStallTimer?.cancel();
    _stopLiveHlsWatchdog();
    _bufferingStartedAt = null;
    _stopSilenceKeepAlive();
    unawaited(_pausedStreamTask.end());
    _lastPlayerErrorCode = null;
    _lastPlayerErrorMessage = null;
    _stopHlsPlaylistRefresh();
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    currentStreamInfo.add(null);
    AnalyticsService.instance.setCurrentStream(url: null, type: null, index: null, total: null);
    await player.stop();
    return super.stop();
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) {
    _log('playFromSearch($query, $extras)');

    final stations = stationDataService.visibleStations;
    if (stations.isEmpty) return super.playFromSearch(query, extras);

    var maxR = 0;
    late Station selectedStation;
    for (var v in stations) {
      var r = partialRatio(v.title, query);
      if (r > maxR) {
        maxR = r;
        selectedStation = v;
      }
    }
    if (maxR > 0) {
      return playStation(selectedStation, fromFavorites: false);
    } else {
      return playStation(stations[0], fromFavorites: false);
    }
  }

  @override
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) {
    for (var v in stationDataService.stations.value) {
      if (v.stationStreams.toString().contains(uri.toString())) {
        return playStation(v, fromFavorites: false);
      }
    }
    return super.playFromUri(uri);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    _log('playMediaItem($mediaItem)');
    // History items: tapping keeps the current station playing
    if (mediaItem.id.startsWith('history_')) return;
    final stationId = mediaItem.extras?["station_id"];
    var station = stationDataService.stations.value.cast<Station?>()
        .firstWhere((element) => element!.id == stationId, orElse: () => null);

    // In release mode, Android Auto can call playMediaItem before stations
    // have loaded from the API. Wait for the first non-empty emission.
    if (station == null && stationDataService.stations.value.isEmpty) {
      _trace('playMediaItem: stations not loaded yet, waiting...');
      try {
        await stationDataService.stations.stream
            .firstWhere((stations) => stations.isNotEmpty)
            .timeout(const Duration(seconds: 10));
        station = stationDataService.stations.value.cast<Station?>()
            .firstWhere((element) => element!.id == stationId, orElse: () => null);
      } catch (e) {
        _trace('playMediaItem: timeout waiting for stations: $e');
      }
    }

    if (station != null) {
      // A category pick (Android Auto) keeps next/previous within it.
      final fromGroup = mediaItem.extras?['fromGroup'] as String?;
      final fromFavorites = fromGroup != null
          ? false
          : mediaItem.extras?['fromFavorites'] as bool?;
      playStation(station, fromFavorites: fromFavorites, fromGroup: fromGroup);
    } else {
      _trace('playMediaItem: station not found for $stationId');
    }
  }

  // Metadata refresh
  SongLikeService get _songLikeService => GetIt.instance<SongLikeService>();

  String _buildSongInfo(Station station) {
    final title = station.songTitle;
    final artist = station.songArtist;
    if (artist.isNotEmpty) return '$title - $artist';
    if (title.isNotEmpty) return title;
    return station.title;
  }

  /// Maps the Cast receiver's player state to AudioProcessingState.
  AudioProcessingState _castProcessingState() {
    if (!GetIt.instance.isRegistered<CastService>()) {
      return AudioProcessingState.ready;
    }
    switch (GetIt.instance<CastService>().castPlayerState.value) {
      case CastMediaPlayerState.buffering:
      case CastMediaPlayerState.loading:
        return AudioProcessingState.buffering;
      case CastMediaPlayerState.idle:
      case CastMediaPlayerState.playing:
      case CastMediaPlayerState.paused:
      case CastMediaPlayerState.unknown:
        return AudioProcessingState.ready;
    }
  }

  /// Re-emits `playbackState` with current controls, processing state, and
  /// the latest known `playing` flag. Callers use this after synthesizing
  /// state changes outside the normal `player.playbackEventStream` path
  /// (e.g., adopting an in-progress Cast session).
  void broadcastCurrentState() {
    _broadcastState(player.playbackEvent);
  }

  /// Single source of truth for "playing" while casting.
  ///
  /// Flipping `playbackState.playing` with `copyWith` alone leaves the
  /// `controls` list stale — the Play/Pause icon is rebuilt inside
  /// `_broadcastState` from the current `playing` value. This helper
  /// does both atomically and is the only sanctioned way to mutate
  /// the Cast-side playing flag.
  ///
  /// Call this from:
  ///   - `play()` / `pause()` / `stop()` Cast branches (optimistic)
  ///   - the main.dart cast-state sync listener (reactive, from receiver)
  ///   - `playStation()` Cast branch (new station loaded)
  ///   - Cast session adoption in main.dart
  void setCastPlaying(bool playing) {
    playbackState.add(playbackState.value.copyWith(playing: playing));
    _broadcastState(player.playbackEvent);
  }

  /// The media session's buttons and the three the compact notification
  /// shows (previous, play or pause, next).
  ///
  /// [onAndroidAuto] gives Now Playing CarPlay's buttons, in its order:
  /// like, favorite, dislike. Android Auto has its own button for the queue
  /// ("Redate recent"), so "Melodii recente", which opens the phone app,
  /// stays on the phone notification.
  static ({List<MediaControl> controls, List<int> compact}) sessionControls({
    required bool onAndroidAuto,
    required bool playing,
    required bool isFav,
    required bool isLiked,
    required bool isDisliked,
  }) {
    final favorite = MediaControl.custom(
      androidIcon:
          isFav ? 'drawable/ic_favorite' : 'drawable/ic_favorite_border',
      label: isFav ? 'Elimină din favorite' : 'Adaugă la favorite',
      name: 'toggleFavorite',
    );
    final history = MediaControl.custom(
      androidIcon: 'drawable/ic_history',
      label: 'Melodii recente',
      name: 'showSongHistory',
    );
    // The thumbs are outlined until the song is liked or disliked.
    final like = MediaControl.custom(
      androidIcon:
          isLiked ? 'drawable/ic_thumb_up' : 'drawable/ic_thumb_up_outline',
      label: isLiked ? 'Retrage like' : 'Îmi place',
      name: 'likeSong',
    );
    final dislike = MediaControl.custom(
      androidIcon: isDisliked
          ? 'drawable/ic_thumb_down'
          : 'drawable/ic_thumb_down_outline',
      label: isDisliked ? 'Retrage dislike' : 'Nu îmi place',
      name: 'dislikeSong',
    );
    final leading =
        onAndroidAuto ? [like, favorite] : [favorite, history, like];
    return (
      controls: [
        ...leading,
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        dislike,
      ],
      // From the buttons' places: an index past the last button once
      // crashed the notification (c12c673).
      compact: [leading.length, leading.length + 1, leading.length + 2],
    );
  }

  void _broadcastState(PlaybackEvent event) {
    // Source of truth for `playing`: media_kit in video mode, the inline
    // YouTube iframe for a UI-owned youtube playlist item, the cast-side flag
    // while casting, else the just_audio player, or the listener's play
    // intent while play() (re)connects.
    final playing = _videoMode
        ? videoService.isPlaying
        : _playlistYoutubeActive
            ? _youtubePlaying
            : isCasting
                ? (playbackState.value.playing)
                : player.playing || _isReconnectingOnIntent;
    // Playback waits for the internet (see setOfflineError): only the
    // local player, and only while the listener wants it on.
    final offlineError = _offlineErrorShown &&
        _hasBeenPlayed &&
        !_videoMode &&
        !_playlistYoutubeActive &&
        !isCasting;
    final station = currentStation.valueOrNull;
    final isFav = station != null &&
        stationDataService.favoriteStationSlugs.value.contains(station.slug);
    final songId = station?.songId ?? -1;
    final likeStatus = _songLikeService.getLikeStatus(songId);
    final isLiked = likeStatus == 1;
    final isDisliked = likeStatus == -1;

    final controls = sessionControls(
      onAndroidAuto: Platform.isAndroid && isCarConnected,
      playing: playing,
      isFav: isFav,
      isLiked: isLiked,
      isDisliked: isDisliked,
    );

    playbackState.add(playbackState.value.copyWith(
      controls: controls.controls,
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.setRating,
        MediaAction.skipToQueueItem,
      },
      androidCompactActionIndices: controls.compact,
      processingState: offlineError
        ? AudioProcessingState.error
        : _isConnecting
        ? AudioProcessingState.loading
        : _videoMode
          ? (videoService.isBuffering
              ? AudioProcessingState.buffering
              : AudioProcessingState.ready)
          : _playlistYoutubeActive
            ? AudioProcessingState.ready
            : isCasting
            ? _castProcessingState()
            : _awaitingAudioStart && player.playing
            ? AudioProcessingState.buffering
            : const {
                // We're using ready here to not interupt Android Auto playback when going to next/previous station
                ProcessingState.idle: AudioProcessingState.ready,
                ProcessingState.loading: AudioProcessingState.loading,
                ProcessingState.buffering: AudioProcessingState.buffering,
                ProcessingState.ready: AudioProcessingState.ready,
                ProcessingState.completed: AudioProcessingState.completed,
              }[player.processingState] ?? AudioProcessingState.idle,
      playing: playing,
      updatePosition: _videoMode
          ? videoService.position
          : _playlistYoutubeActive
              ? _youtubePosition
              : player.position,
      bufferedPosition: _videoMode
          ? videoService.position
          : _playlistYoutubeActive
              ? _youtubePosition
              : player.bufferedPosition,
      speed: player.speed,
      errorCode: offlineError ? _errorCodeUnknown : null,
      errorMessage: offlineError ? _offlineErrorMessage : null,
    ));
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    _log('getMediaItem($mediaId)');
    final result = await super.getMediaItem(mediaId);
    _log('getMediaItem -> $result');
    return result;
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    _log('search($query, $extras)');
    if (query.isEmpty) return stationsMediaItems.value;
    final lowerQuery = query.toLowerCase();
    final results = stationsMediaItems.value.where((item) {
      final title = item.title.toLowerCase();
      final artist = (item.artist ?? '').toLowerCase();
      final displayTitle = (item.displayTitle ?? '').toLowerCase();
      final displaySubtitle = (item.displaySubtitle ?? '').toLowerCase();
      return title.contains(lowerQuery) ||
          artist.contains(lowerQuery) ||
          displayTitle.contains(lowerQuery) ||
          displaySubtitle.contains(lowerQuery);
    }).toList();
    _log('search -> ${results.length} results');
    return results;
  }

  @override
  Future<void> onTaskRemoved() {
    _trace('onTaskRemoved()');
    // Don't stop audio if CarPlay/Android Auto is connected — user may still be listening
    try {
      final carPlayService = GetIt.instance<CarPlayService>();
      if (carPlayService.isConnected) {
        _trace('onTaskRemoved: CarPlay/Android Auto connected, keeping audio alive');
        return super.onTaskRemoved();
      }
    } catch (_) {}
    // Stop Cast playback explicitly — the native stopCastingOnAppTerminated
    // flag handles this too, but an explicit stop is more reliable when the
    // OS kills the process abruptly.
    try {
      if (isCasting) {
        _trace('onTaskRemoved: stopping Cast playback');
        GetIt.instance<CastService>().disconnect();
      }
    } catch (_) {}
    _cancelInFlightPlay();
    _disconnectTimer?.cancel();
    _stopLiveHlsWatchdog();
    _stopHlsPlaylistRefresh();
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    AnalyticsService.instance.endListening(reason: 'app_killed');
    AnalyticsService.instance.flush();
    player.stop();
    // Not dispose(): the process can outlive the task (audio_service caches
    // the engine), and a relaunch reuses this very service.
    stationDataService.suspend();
    return super.onTaskRemoved();
  }

  // Method to completely stop and cleanup the audio service
  Future<void> dispose() async {
    _trace('dispose()');
    _cancelInFlightPlay();
    _disconnectTimer?.cancel();
    _bufferingStallTimer?.cancel();
    _stopLiveHlsWatchdog();
    _stopHlsPlaylistRefresh();
    _hlsHttp.close();
    await _holdProxyNetworkSub?.cancel();
    await _holdProxy?.stop();
    _stopSilenceKeepAlive();
    for (final s in _videoSubs) {
      await s.cancel();
    }
    _videoSubs.clear();
    _cancelVideoFallbackWatchdog();
    await audioOnlyFallback.close();
    await _carRouteSub?.cancel();
    await _castRouteSub?.cancel();
    await _castSessionSub?.cancel();
    await _playCountSub?.cancel();
    _playCountTracker.dispose();
    await _exitVideoMode(stopVideo: true);
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    await player.stop();
    await player.dispose();
    await _silenceKeeper.dispose();
    stationDataService.dispose();
    await super.stop();
  }

  @override
  Future<void> prepareFromSearch(String query, [Map<String, dynamic>? extras]) {
    _log('prepareFromSearch($query, $extras)');
    return super.prepareFromSearch(query, extras);
  }

  @override
  Future<void> prepareFromUri(Uri uri, [Map<String, dynamic>? extras]) {
    _log('prepareFromSearch($uri, $extras)');
    return super.prepareFromUri(uri, extras);
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) {
    _log('click($button)');
    // A headset or Bluetooth button: why the audio paused or started.
    AnalyticsService.instance.log('media button', {'button': button.name});
    return super.click(button);
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    _trace('playFromMediaId($mediaId, $extras)');
    // History items: tapping keeps the current station playing
    if (mediaId.startsWith('history_')) return;
    // The id names the list it was picked from: the favorites, a category,
    // or else the full list (all stations, search results).
    final (:stationMediaId, :fromFavorites, :fromGroup) =
        AndroidAutoBrowseIds.parseItem(mediaId);
    var selectedMediaItem = stationsMediaItems.value.cast<MediaItem?>()
        .firstWhere((item) => item!.id == stationMediaId, orElse: () => null);

    // Wait for stations to load if not yet available (release mode race condition)
    if (selectedMediaItem == null && stationsMediaItems.value.isEmpty) {
      _trace('playFromMediaId: waiting for stations to load...');
      try {
        await stationsMediaItems.stream
            .firstWhere((items) => items.isNotEmpty)
            .timeout(const Duration(seconds: 10));
        selectedMediaItem = stationsMediaItems.value.cast<MediaItem?>()
            .firstWhere((item) => item!.id == stationMediaId,
                orElse: () => null);
      } catch (e) {
        _trace('playFromMediaId: timeout waiting for stations: $e');
      }
    }

    if (selectedMediaItem != null) {
      // playMediaItem reads the navigation context from the extras.
      return playMediaItem(selectedMediaItem.copyWith(extras: {
        ...?selectedMediaItem.extras,
        'fromFavorites': fromFavorites,
        'fromGroup': fromGroup,
      }));
    }
  }

  /// Reconnect if the stream was silently lost or the user-intent says
  /// "play" but the player isn't. Decision delegated to [ReconnectPolicy]
  /// so the timing rules (debounce, who bypasses it) live in one
  /// unit-testable place.
  ///
  /// [trigger] determines whether the just-loaded debounce applies:
  ///   - networkRestored: bypass (a real reconnect signal)
  ///   - lifecycleResumed / terminalState: honor (AVPlayer noise)
  void reconnectIfNeeded({
    ReconnectTrigger trigger = ReconnectTrigger.lifecycleResumed,
  }) {
    final shouldReconnect = ReconnectPolicy.shouldReconnect(
      trigger: trigger,
      now: DateTime.now(),
      lastSuccessfulLoadAt: _lastSuccessfulLoadAt,
      processingState: player.processingState,
      playing: player.playing,
      hasStation: currentStation.valueOrNull != null,
      hasBeenPlayed: _hasBeenPlayed,
      isConnecting: _isConnecting,
      isCasting: isCasting,
    );
    if (!shouldReconnect) {
      _trace("reconnectIfNeeded(${trigger.name}): no-op "
          "(state=${player.processingState}, playing=${player.playing})");
      return;
    }
    _trace("reconnectIfNeeded(${trigger.name}): reconnecting "
        "(state=${player.processingState}, playing=${player.playing})");
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    play();
  }

  // Last played station
  setLastPlayedStation(Station station) async {
    await _prefs.setString(LAST_PLAYED_MEDIA_ITEM, station.slug);
  }

  Future<Station?> getLastPlayedStation() async {
    // A hidden station left the lists, so a launch doesn't start it again.
    final stations = stationDataService.visibleStations;
    if (stations.isEmpty) return null;
    var stationSlug = _prefs.getString(LAST_PLAYED_MEDIA_ITEM);
    return stations.firstWhere(
      (station) => station.slug == stationSlug,
      orElse: () => stations.first,
    );
  }

  Future<void> setStationIsFavorite(Station station, bool isFavorite) async {
    await _storeFavorite(station, isFavorite);
    if (isFavorite) _countReviewAction();
  }

  Future<void> _storeFavorite(
    Station station,
    bool isFavorite, {
    int? index,
  }) async {
    await stationDataService.setStationIsFavorite(station, isFavorite,
        index: index);
    // Update MediaItem rating so MediaSession reflects the new favorite state
    final currentItem = mediaItem.valueOrNull;
    if (currentItem != null && currentStation.value?.slug == station.slug) {
      mediaItem.add(currentItem.copyWith(rating: Rating.newHeartRating(isFavorite)));
      // Update notification/Android Auto favorite icon
      _broadcastState(player.playbackEvent);
    }
  }

  /// Hides [station] from every station list, the car's included. A
  /// favorite stops being one, since the favorites only list stations on
  /// show. Playing it goes on: it is hidden, not stopped.
  ///
  /// Returns the place [station] had among the favorites, null if it was
  /// not one, for [unhideStation] to put it back there.
  int? hideStation(Station station) {
    final favoriteIndex =
        stationDataService.favoriteStationSlugs.value.indexOf(station.slug);
    // Both lists change before this returns, so they redraw together.
    unawaited(stationDataService.setStationIsHidden(station, true));
    if (favoriteIndex < 0) return null;
    unawaited(_storeFavorite(station, false));
    return favoriteIndex;
  }

  /// Shows [station] in the lists again, back among the favorites at
  /// [favoriteIndex] (an undone hide of a favorite, see [hideStation]).
  Future<void> unhideStation(Station station, {int? favoriteIndex}) async {
    final showing = stationDataService.setStationIsHidden(station, false);
    // The full player's heart still works on a hidden station playing.
    if (favoriteIndex != null &&
        !stationDataService.favoriteStationSlugs.value
            .contains(station.slug)) {
      await _storeFavorite(station, true, index: favoriteIndex);
    }
    await showing;
  }

  /// Adds [station] to the favorites or removes it, going by the favorites
  /// as they are now rather than as a widget last drew them, so taps in
  /// quick succession each undo the one before. Returns whether [station]
  /// is a favorite afterwards.
  bool toggleStationFavorite(Station station) {
    final isFavorite = !stationDataService.favoriteStationSlugs.value
        .contains(station.slug);
    unawaited(setStationIsFavorite(station, isFavorite));
    return isFavorite;
  }

  /// Counts a user action toward the review dialog thresholds.
  void _countReviewAction() => unawaited(Utils.incrementActionsMade());

  void _initUpdateCurrentStationMetadata() {
    // When mobile data toggles: re-emit metadata with station thumbnail.
    // Metadata text (song name/artist) is always shown since differential
    // fetching is lightweight. Only difference: skip song thumbnail download.
    NetworkService.instance.isOnMobileData.stream.listen((onMobile) {
      _log("isOnMobileData changed: $onMobile");
      // Keep the playlist item's own metadata (see refreshCurrentMetadata).
      if (_playlistMode) return;
      final station = currentStation.valueOrNull;
      if (station == null || mediaItem.valueOrNull == null) return;

      // Re-emit with station thumbnail (cached on disk, no download needed)
      final item = _buildStationMediaItem(station);
      _lastEmittedSongId = onMobile ? -1 : station.songId;
      final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
      mediaItem.add(item.copyWith(rating: Rating.newHeartRating(isFav)));
      if (!onMobile) {
        _ensureStationArtCached(station);
      }
    });

    // Car connect/disconnect re-emits metadata through CarPlayService,
    // which calls refreshCurrentMetadata() itself (it registers after this
    // handler, so it cannot be subscribed to from here).

    // When connectivity is restored: always attempt reconnect. The earlier
    // foreground-only gate prevented background recovery — but
    // reconnectIfNeeded() already no-ops when there's no station, while
    // connecting, casting, or not stalled, so the gate was redundant and
    // actively harmful for the "audio that never stops" goal.
    //
    // Delay before reconnect: see networkRestoreReconnectDelay. Pre-fix
    // this was 2s and was the dominant contributor to "stream is delayed
    // when network returns".
    //
    // Trigger: networkRestored explicitly bypasses the just-loaded
    // debounce in reconnectIfNeeded. Pre-fix the debounce silently
    // suppressed recovery when airplane-mode toggled within 8s of a
    // successful load — the user-perceived "audio never came back" bug.
    //
    // A play() loop still retrying (it outlived the outage) is woken from
    // its backoff instead: reconnectIfNeeded() skips while it connects.
    //
    // skip(1): the current value comes first, at startup, and is no
    // restore. Taken for one, its check restarted the station autoplay had
    // just started (AVPlayer buffering right after play() reads as
    // stalled): the button showed pause, then the spinner again, before
    // any audio came out.
    final network = NetworkService.instance;
    network.isOffline.stream.skip(1).listen((offline) {
      if (offline) {
        _lastOfflineAt = DateTime.now();
        _noteOutageStart();
        return;
      }
      final restoredAt = DateTime.now();
      _failover.forgetFailures();
      // audio_service downloads the artwork of the lock screen and of
      // CarPlay's Now Playing each time the media item is sent, and never
      // again after a failure: sent again, an artwork that failed offline
      // shows now instead of at the next song.
      refreshCurrentMetadata();
      // Refresh the live-HLS origin state now rather than at the next 10 s
      // poll, so the liveness rules judge the stream by what the origin
      // says after the outage.
      if (_isLocalLiveHls && _loadedStreamUrl != null) {
        unawaited(_pollHlsPlaylist());
      }
      _trace("isOffline -> false: will reconnect in "
          "${ReconnectPolicy.networkRestoreReconnectDelay.inMilliseconds}ms");
      Future.delayed(ReconnectPolicy.networkRestoreReconnectDelay, () {
        if (network.isOffline.value) return; // dropped again meanwhile
        _trace("isOffline -> false: checking if player needs reconnect");
        _wakeRetryBackoff();
        reconnectIfNeeded(trigger: ReconnectTrigger.networkRestored);
        _scheduleOutageLoadCheck(restoredAt);
      });
    });

    // A network back whose internet does not answer yet (a weak signal
    // whose probes time out, a blocked probe host) ends the no-network
    // backoff too: the loop's own attempts are the best check there is.
    var lastStatus = network.status.value;
    network.status.stream.listen((status) {
      final wasWithoutNetwork = lastStatus == ConnectionStatus.offline;
      if (status != ConnectionStatus.noInternet) {
        _noInternetSince = null;
      } else if (lastStatus != ConnectionStatus.noInternet) {
        _noInternetSince = DateTime.now();
      }
      lastStatus = status;
      if (wasWithoutNetwork && status == ConnectionStatus.noInternet) {
        _wakeRetryBackoff();
      }
    });

    // Rechecks of a lost internet only matter while someone would see or
    // hear the answer: the app on screen, or audio playing or connecting
    // (also on a car screen or a cast device).
    network.isInternetWanted = () {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final onScreen = lifecycle == null ||
          lifecycle == AppLifecycleState.resumed ||
          lifecycle == AppLifecycleState.inactive;
      return onScreen ||
          player.playing ||
          _isConnecting ||
          isCasting ||
          isCarConnected;
    };

    // Station data poll: update metadata when stations change.
    stationDataService.stations.stream.listen((stations) {
      _log("updateCurrentStationMetadata");

      Station? updatedCurrentStation;
      if(currentStation.valueOrNull != null) {
        updatedCurrentStation = stations.cast<Station?>().firstWhere((element) => element!.id == currentStation.value!.id, orElse: () => null);
        if (updatedCurrentStation != null) currentStation.add(updatedCurrentStation);
      }

      _publishStationsMediaItems();

      if (mediaItem.value != null && updatedCurrentStation != null) {
        final newSongId = updatedCurrentStation.songId;
        final songChanged = newSongId != _lastEmittedSongId;

        // A playlist item publishes its own metadata.
        if (songChanged && !_playlistMode) {
          final isFav = stationDataService.favoriteStationSlugs.value.contains(updatedCurrentStation.slug);

          // Always show metadata text (song name/artist) — differential fetching is lightweight.
          // Data saving modes (mobile data, car, unstable) only differ in thumbnail handling:
          // they use the station thumbnail (cached on disk) instead of downloading song thumbnails.
          final newItem = _buildStationMediaItem(updatedCurrentStation);
          _lastEmittedSongId = newSongId;
          mediaItem.add(newItem.copyWith(rating: Rating.newHeartRating(isFav)));

          // Push updated metadata to Cast device in real-time
          if (isCasting) {
            try {
              GetIt.instance<CastService>().updateCastMetadata(updatedCurrentStation);
            } catch (e) {
              _log('Cast metadata update failed: $e');
              AnalyticsService.instance
                  .logWarning('cast metadata update failed', {'error': '$e'});
            }
          }

          // In unstable mode, additionally pre-cache song thumbnails to disk
          if (SeekModeManager.isUnstableConnection) {
            _ensureSongThumbnailCachedPermanently(updatedCurrentStation);
          }

          // Refresh queue with latest song history when song changes
          _updateSongHistoryQueue();
        }
      }
    });

    // A station hidden or shown again leaves or joins the browse tree.
    stationDataService.hiddenStationSlugs.stream
        .skip(1)
        .listen((_) => _publishStationsMediaItems());
  }

  /// Rebuilds [stationsMediaItems], the stations Android Auto's media
  /// browser lists, browses and searches.
  void _publishStationsMediaItems() {
    // Use the app's sort preference for the media browse tree so Android
    // Auto's built-in media browser matches the custom UI order.
    // Always use HTTPS artUri (not file:// cached paths) because Android
    // Auto's system player runs in a separate process.
    // Unfiltered: the phone's station-group filter cannot be seen or
    // changed from the car, so browse, search, and playFromMediaId must
    // cover the whole catalog (hidden stations aside).
    final sortedStations =
        stationDataService.getSortedStations(applyGroupFilter: false);
    final newStationsMediaItems = sortedStations.map((station) {
      final thumbnailUrl = station.rawStationData.thumbnail_url;
      final artUri = (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
          ? Uri.parse(thumbnailUrl)
          : Uri.parse(CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL);
      final item = station.mediaItem;
      // Strip "Radio " prefix for the A-Z alphabet index so letters
      // distribute evenly instead of clustering under "R".
      final title = station.rawStationData.title;
      final sortKey = title.startsWith('Radio ')
          ? title.substring(6)
          : title;
      final extras = Map<String, dynamic>.from(item.extras ?? {});
      extras['android.media.extra.SORT_KEY'] = sortKey;
      return item.copyWith(
        artUri: artUri,
        // The second line of CarPlay's rows: the song, or "Listă de redare"
        // for a playlist station. `artist` keeps the song for the search.
        displaySubtitle: CarPlayService.computeStationListSubtitle(
              displaySubtitle: station.displaySubtitle,
              isPlaylist: station.isPlaylist,
              isRomanian: true,
            ) ??
            '',
        extras: extras,
      );
    }).toList();

    stationsMediaItems.add(newStationsMediaItems);
  }
}
