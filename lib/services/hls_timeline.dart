import 'dart:io' show Platform;

import 'hls_playhead_clock.dart';
import 'hls_playlist_snapshot.dart';
import 'hls_wall_clock_map.dart';

export 'hls_playhead_clock.dart';
export 'hls_playlist_snapshot.dart';
export 'hls_wall_clock_map.dart';
export 'song_boundary_queue.dart';

/// Inputs for the live-HLS liveness rules, sampled on the watchdog tick.
///
/// Everything is in media time (segments) or measured by the app's own
/// successful playlist polls, never from `player.position`.
class LiveHlsHealthSample {
  /// Segment holding the playhead; null until the clock is anchored.
  final int? playheadSeq;

  /// Media seconds from the playhead to the end of the newest published
  /// segment (negative once the playhead ran past it).
  final double? edgeLagSeconds;

  /// First segment of the latest playlist.
  final int? windowFirstSeq;

  /// The latest playlist does not continue the recorded media (sequence
  /// restart or renumbering): the playhead is outside the window.
  final bool windowReset;

  /// When the live edge last grew.
  final DateTime? originAdvancedAt;

  /// Edge growth stall proven by successful polls: at least two of them
  /// returned the same edge and they span 3 target durations. Null when not
  /// proven. A failed poll never ages the origin.
  final Duration? originStaleFor;

  /// Time since the last successful poll, once two polls in a row failed.
  final Duration? originUnreachableFor;

  /// [edgeLagSeconds] when the stall was first proven. Small values mean
  /// instant / near-edge geometry, where short origin stalls are routine.
  final double? edgeLagAtStall;

  /// When the native buffered position last changed.
  final DateTime? bufferedChangedAt;

  /// Start of the current playing && ready run (grace baseline).
  final DateTime? advancingSince;

  /// `EXT-X-TARGETDURATION` (seconds).
  final double targetDuration;

  const LiveHlsHealthSample({
    this.playheadSeq,
    this.edgeLagSeconds,
    this.windowFirstSeq,
    this.windowReset = false,
    this.originAdvancedAt,
    this.originStaleFor,
    this.originUnreachableFor,
    this.edgeLagAtStall,
    this.bufferedChangedAt,
    this.advancingSince,
    this.targetDuration = HlsTimeline.defaultTargetDuration,
  });
}

/// The live-HLS playback timeline: audible clock, origin progress and the
/// inputs of the liveness rules.
///
/// Pure (time is always passed in) and owned by `AppAudioHandler`, which
/// feeds it player events and its own playlist polls. The audible instant is
/// `segment.pdt + σ(segment) + offset`: the server wall-clock time of the
/// audio the listener hears, frozen while paused or buffering.
class HlsTimeline {
  /// Platforms whose live-HLS native position is window-relative and was
  /// validated against ground truth (AVPlayer, ExoPlayer). Read by the
  /// handler only; no timeline logic depends on the host platform.
  static bool get isSupportedPlatform =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// Snapshots kept for anchoring.
  static const int recentSnapshotCount = 6;

  /// Segments kept behind the playhead, so a re-anchor (at most one segment
  /// away from a projected anchor) still finds its segment.
  static const int ledgerMarginSegments = 4;

  /// Used until a playlist reports its own target duration.
  static const double defaultTargetDuration = 6;

  /// AVPlayer plays live HLS three target durations behind the edge.
  static const Duration darwinHoldBack = Duration(seconds: 18);

  /// A recorded segment whose PDT moved by more than this was re-dated by
  /// the backend (a PDT re-anchor), not jittered.
  static const double redateThresholdSeconds = 0.5;

  final HlsSegmentLedger _ledger = HlsSegmentLedger();
  late final HlsPlayheadClock _clock = HlsPlayheadClock(_ledger);
  final HlsWallClockMap _wallMap = HlsWallClockMap();
  final List<HlsPlaylistSnapshot> _snapshots = [];

  String? _edgeUri;
  DateTime? _originAdvancedAt;
  DateTime? _lastPollOkAt;
  int _unchangedPolls = 0;
  int _failedPolls = 0;
  double? _edgeLagAtStall;
  bool _windowReset = false;
  int? _windowFirstSeq;
  double _targetDuration = defaultTargetDuration;
  Duration? _buffered;
  DateTime? _bufferedChangedAt;
  bool _lacksPdt = false;
  bool _justAnchored = false;

  /// Approximate listening latency when no PDT clock exists: the offset plus
  /// the player's own hold-back. Documented approximation (no-PDT streams,
  /// Windows/Linux).
  static Duration approximateLatency(Duration offset, {required bool darwin}) =>
      darwin ? offset + darwinHoldBack : offset;

  bool get isAnchored => _clock.isAnchored;
  bool get isExactlyAnchored => _clock.quality == HlsAnchorQuality.exact;
  bool get isAdvancing => _clock.isAdvancing;
  DateTime? get advancingSince => _clock.advancingSince;

  /// Quality of the current anchor; [HlsAnchorQuality.approximate] for a
  /// playlist without PROGRAM-DATE-TIME.
  HlsAnchorQuality? get anchorQuality =>
      _lacksPdt ? HlsAnchorQuality.approximate : _clock.quality;

  /// The stream has no PROGRAM-DATE-TIME: the owner must approximate the
  /// audible instant itself.
  bool get lacksProgramDateTime => _lacksPdt;

  /// Gap between the anchoring report and its snapshot (log telemetry).
  Duration? get anchorSnapshotGap => _clock.anchorSnapshotGap;

  /// New load: forget everything.
  void beginLoad() => reset();

  void reset() {
    _ledger.clear();
    _clock.beginLoad();
    _wallMap.reset();
    _snapshots.clear();
    _edgeUri = null;
    _originAdvancedAt = null;
    _lastPollOkAt = null;
    _unchangedPolls = 0;
    _failedPolls = 0;
    _edgeLagAtStall = null;
    _windowReset = false;
    _windowFirstSeq = null;
    _targetDuration = defaultTargetDuration;
    _buffered = null;
    _bufferedChangedAt = null;
    _lacksPdt = false;
    _justAnchored = false;
  }

  /// Edge-triggered: true once after every (re)anchor.
  bool takeJustAnchored() {
    final anchored = _justAnchored;
    _justAnchored = false;
    return anchored;
  }

  /// Re-checks settle-then-anchor without a new event (nothing else is
  /// guaranteed to arrive: ExoPlayer reports once, ~0.1 s after ready).
  void tick(DateTime now) {
    _clock.advanceTo(now);
    _tryAnchor(now);
  }

  /// A successful playlist poll.
  void onSnapshot(HlsPlaylistSnapshot s, DateTime now) {
    _lacksPdt = false;
    if (s.targetDuration > 0) _targetDuration = s.targetDuration;
    _recordOriginProgress(s.segments.last.uri, now);
    _absorb(s);
    _tryAnchor(now);
    if (_staleProven && _edgeLagAtStall == null) {
      _edgeLagAtStall = _edgeLag(_clock.positionAt(now));
    }
    _pruneBehindPlayhead(now);
  }

  /// A failed or timed-out poll. Never ages the origin: one lost poll must
  /// not look like a frozen playlist.
  void onPollFailed(DateTime now) => _failedPolls++;

  /// A successful poll of a playlist without PROGRAM-DATE-TIME.
  void onPlaylistWithoutPdt(DateTime now) {
    _lastPollOkAt = now;
    _failedPolls = 0;
    if (_lacksPdt) return;
    _lacksPdt = true;
    _justAnchored = true;
  }

  void onPlayerEvent({
    required bool playing,
    required bool ready,
    required Duration updatePosition,
    required DateTime updateTime,
    required Duration bufferedPosition,
    required DateTime now,
  }) {
    _clock.onPlayerEvent(
      advancing: playing && ready,
      updatePosition: updatePosition,
      updateTime: updateTime,
      at: now,
    );
    if (bufferedPosition != _buffered) {
      _buffered = bufferedPosition;
      _bufferedChangedAt = now;
    }
    _tryAnchor(now);
  }

  /// Whether a fresh playlist fetch can still help anchoring: not exactly
  /// anchored while advancing, and either no snapshot exists or one fetched
  /// now would still match the latest report.
  bool needsAnchorSnapshot(DateTime now) {
    if (isExactlyAnchored || _lacksPdt || !_clock.isAdvancing) return false;
    if (_snapshots.isEmpty) return true;
    final reportAt = _clock.nativeUpdateTime;
    if (reportAt == null) return false;
    const match = HlsPlayheadClock.snapshotMatch;
    final matched =
        _snapshots.any((s) => s.fetchedAt.difference(reportAt).abs() <= match);
    return !matched && now.difference(reportAt) <= match;
  }

  /// PROGRAM-DATE-TIME of the audio at the playhead (encoder clock).
  double? playheadPdt(DateTime now) {
    final pos = _clock.positionAt(now);
    final entry = pos == null ? null : _ledger[pos.seq];
    return entry == null ? null : entry.pdt + pos!.offset;
  }

  /// σ of the segment under the playhead, or of the current epoch.
  double? skewSeconds(DateTime now) {
    final pos = _clock.positionAt(now);
    final entry = pos == null ? null : _ledger[pos.seq];
    return entry == null
        ? _wallMap.skewSeconds
        : _wallMap.sigmaFor(entry.epoch);
  }

  /// Server wall-clock instant of the audio the listener hears; null until
  /// anchored with a known skew.
  ///
  /// The segment's own σ (its skew epoch) maps the PDT it was first seen
  /// with, so neither a later skew step nor a re-dating moves audio that
  /// was already published.
  DateTime? audibleInstant(DateTime now) {
    final pos = _clock.positionAt(now);
    final entry = pos == null ? null : _ledger[pos.seq];
    final sigma = entry == null ? null : _wallMap.sigmaFor(entry.epoch);
    if (entry == null || sigma == null) return null;
    final seconds = entry.wallPdt + sigma + pos!.offset;
    return DateTime.fromMicrosecondsSinceEpoch((seconds * 1e6).round(),
        isUtc: true);
  }

  LiveHlsHealthSample healthSample(DateTime now) {
    final pos = _clock.positionAt(now);
    final lastOk = _lastPollOkAt;
    final advancedAt = _originAdvancedAt;
    return LiveHlsHealthSample(
      playheadSeq: pos?.seq,
      edgeLagSeconds: _edgeLag(pos),
      windowFirstSeq: _windowFirstSeq,
      windowReset: _windowReset,
      originAdvancedAt: advancedAt,
      originStaleFor: _staleProven ? lastOk!.difference(advancedAt!) : null,
      originUnreachableFor:
          (_failedPolls >= 2 && lastOk != null) ? now.difference(lastOk) : null,
      edgeLagAtStall: _edgeLagAtStall,
      bufferedChangedAt: _bufferedChangedAt,
      advancingSince: _clock.advancingSince,
      targetDuration: _targetDuration,
    );
  }

  /// At least two successful polls returned the same edge, spanning
  /// 3 target durations.
  bool get _staleProven {
    final lastOk = _lastPollOkAt;
    final advancedAt = _originAdvancedAt;
    if (_unchangedPolls < 2 || lastOk == null || advancedAt == null) {
      return false;
    }
    final span = lastOk.difference(advancedAt).inMicroseconds / 1e6;
    return span >= 3 * _targetDuration;
  }

  /// Origin progress follows the newest segment's URI, not MEDIA-SEQUENCE:
  /// a restarted playlist grows with a constant sequence.
  void _recordOriginProgress(String edgeUri, DateTime now) {
    _lastPollOkAt = now;
    _failedPolls = 0;
    if (edgeUri != _edgeUri) {
      _edgeUri = edgeUri;
      _originAdvancedAt = now;
      _unchangedPolls = 0;
      _edgeLagAtStall = null;
    } else {
      _unchangedPolls++;
    }
  }

  void _absorb(HlsPlaylistSnapshot s) {
    _windowFirstSeq = s.firstSeq;
    if (!_ledger.continues(s)) {
      if (_clock.isAnchored) {
        // The anchored media is gone from the playlist. Keep measuring it;
        // the liveness rule reports the eviction.
        _windowReset = true;
        return;
      }
      _ledger.clear();
      _wallMap.reset();
      _snapshots.clear();
    }
    final shift = _ledger.pdtShiftOf(s);
    if (shift != null && shift.abs() > redateThresholdSeconds) {
      _wallMap.startEpoch();
    }
    final rebaseFrom = _wallMap.add(s);
    _ledger.merge(s, epoch: _wallMap.epoch, sample: _wallMap.latestSample);
    if (rebaseFrom != null) {
      _ledger.reassignEpoch(fromSample: rebaseFrom, epoch: _wallMap.epoch);
    }
    _snapshots.add(s);
    if (_snapshots.length > recentSnapshotCount) _snapshots.removeAt(0);
  }

  void _tryAnchor(DateTime now) {
    if (_lacksPdt) return;
    if (_clock.tryAnchor(now, _snapshots)) _justAnchored = true;
  }

  double? _edgeLag(HlsMediaPosition? pos) =>
      pos == null ? null : _ledger.secondsToEnd(pos);

  void _pruneBehindPlayhead(DateTime now) {
    _clock.advanceTo(now);
    final pos = _clock.positionAt(now);
    if (pos != null) _ledger.pruneBefore(pos.seq - ledgerMarginSegments);
  }
}
