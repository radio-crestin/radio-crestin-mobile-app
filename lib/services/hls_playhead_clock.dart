import 'dart:collection';

import 'hls_playlist_snapshot.dart';

/// One segment as first published, with the skew epoch it belongs to.
class HlsLedgerEntry {
  final String uri;

  /// PROGRAM-DATE-TIME (encoder clock, seconds since epoch), as last
  /// published.
  final double pdt;

  /// PROGRAM-DATE-TIME when first seen. A re-dated segment was still
  /// published at the same wall-clock time, so the wall mapping keeps using
  /// the PDT domain its skew epoch was measured in.
  final double wallPdt;

  /// EXTINF (seconds).
  final double duration;

  /// Skew epoch of the poll that first saw this segment (see
  /// `HlsWallClockMap`).
  int epoch;

  /// Index of the skew sample taken by that poll.
  final int firstSample;

  HlsLedgerEntry({
    required this.uri,
    required this.pdt,
    required this.wallPdt,
    required this.duration,
    required this.epoch,
    required this.firstSample,
  });
}

/// Every segment seen since the anchor, by media sequence number.
///
/// The playhead is tracked in media time (segment + offset), so its PDT and
/// wall-clock instant are always read from the segment that contains it.
/// Integrating in the PDT domain across segments would fall behind by every
/// forward PDT jump the backend inserts after a stall (backend contract C-1).
class HlsSegmentLedger {
  /// Bound on remembered segments (~30 min of 6 s segments).
  static const int maxEntries = 300;

  final SplayTreeMap<int, HlsLedgerEntry> _entries =
      SplayTreeMap<int, HlsLedgerEntry>();

  /// Segments below this were pruned behind the playhead; later polls (whose
  /// window still lists them) must not bring them back.
  int? _floor;

  HlsLedgerEntry? operator [](int seq) => _entries[seq];

  bool get isEmpty => _entries.isEmpty;
  int? get lastSeq => _entries.isEmpty ? null : _entries.lastKey();

  /// Whether [s] continues the recorded media: no known sequence number
  /// names a different segment, and the sequence did not restart below
  /// everything recorded (a playlist reset on today's backend).
  bool continues(HlsPlaylistSnapshot s) {
    if (_entries.isEmpty) return true;
    if (s.lastSeq < _entries.firstKey()!) return false;
    for (final seg in s.segments) {
      final known = _entries[seg.seq];
      if (known != null && known.uri != seg.uri) return false;
    }
    return true;
  }

  /// How far [s] moved the PDT of the newest segment already recorded
  /// (seconds), or null when it shares none. Non-zero only when the backend
  /// re-dates published segments.
  double? pdtShiftOf(HlsPlaylistSnapshot s) {
    for (final seg in s.segments.reversed) {
      final known = _entries[seg.seq];
      if (known != null && known.uri == seg.uri) return seg.pdt - known.pdt;
    }
    return null;
  }

  /// Records the segments of [s]. A known segment keeps its epoch and
  /// first-seen PDT, but is read with the newest PDT and duration.
  void merge(HlsPlaylistSnapshot s, {required int epoch, required int sample}) {
    final floor = _floor;
    for (final seg in s.segments) {
      if (floor != null && seg.seq < floor) continue;
      final known = _entries[seg.seq];
      _entries[seg.seq] = HlsLedgerEntry(
        uri: seg.uri,
        pdt: seg.pdt,
        wallPdt: known?.wallPdt ?? seg.pdt,
        duration: seg.duration,
        epoch: known?.epoch ?? epoch,
        firstSample: known?.firstSample ?? sample,
      );
    }
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.firstKey());
    }
  }

  /// Moves segments first seen at or after [fromSample] to [epoch].
  void reassignEpoch({required int fromSample, required int epoch}) {
    for (final e in _entries.values) {
      if (e.firstSample >= fromSample) e.epoch = epoch;
    }
  }

  /// Media seconds from [position] to the end of the newest recorded
  /// segment. Negative once the playhead ran past it. Null when
  /// [position]'s segment is unknown.
  double? secondsToEnd(HlsMediaPosition position) {
    if (_entries[position.seq] == null) return null;
    var total = -position.offset;
    for (final e in _entries.entries) {
      if (e.key >= position.seq) total += e.value.duration;
    }
    return total;
  }

  /// Drops every segment before [seq], for good.
  void pruneBefore(int seq) {
    _floor = seq;
    _entries.removeWhere((k, _) => k < seq);
  }

  void clear() {
    _entries.clear();
    _floor = null;
  }
}

/// How the playhead was anchored.
enum HlsAnchorQuality {
  /// A native position report matched a playlist snapshot fetched within
  /// [HlsPlayheadClock.snapshotMatch] of it (measured error <= 0.1 s).
  exact,

  /// No snapshot matched: the nearest one was shifted by the time between
  /// its fetch and the report (error up to one segment).
  projected,

  /// The stream carries no PROGRAM-DATE-TIME: `now - (offset + hold-back)`.
  approximate,
}

/// Position of the audible playhead, in media time.
///
/// Anchored once per load from a native position report plus the playlist
/// snapshot fetched alongside the player's own, then advanced by wall time
/// while just_audio reports playing && ready. It deliberately never re-reads
/// window-relative positions mid-session: they jump by whole segments as the
/// window slides, and Dart synthesizes extrapolated, duration-capped reports
/// on play/pause/seek. The one exception is upgrading a non-exact anchor
/// with a later report that does match a snapshot.
class HlsPlayheadClock {
  /// Continuous playing && ready time after which the latest report is the
  /// native one (Darwin timeControlStatus=playing, ExoPlayer READY ~0.1 s
  /// after ready). Dart's synthesized play/seek reports are superseded by
  /// then.
  static const Duration settle = Duration(seconds: 1);

  /// Largest gap between a native report and the snapshot used to resolve
  /// it, keeping the player's and the app's window within one slide.
  static const Duration snapshotMatch = Duration(seconds: 5);

  /// Continuous playing && ready time after which a projected anchor is
  /// accepted when no snapshot matched (first poll failed).
  static const Duration projectAfter = Duration(seconds: 10);

  final HlsSegmentLedger _ledger;

  HlsPlayheadClock(this._ledger);

  HlsMediaPosition? _position;
  DateTime? _lastAt;
  bool _advancing = false;
  DateTime? _advancingSince;
  HlsAnchorQuality? _quality;
  Duration? _nativePosition;
  DateTime? _nativeTime;
  DateTime? _anchorNativeTime;
  Duration? _anchorSnapshotGap;

  bool get isAnchored => _position != null;
  HlsAnchorQuality? get quality => _quality;
  bool get isAdvancing => _advancing;

  /// Start of the current playing && ready run.
  DateTime? get advancingSince => _advancingSince;

  /// `updateTime` of the latest position report.
  DateTime? get nativeUpdateTime => _nativeTime;

  /// Gap between the anchoring report and its snapshot (log telemetry).
  Duration? get anchorSnapshotGap => _anchorSnapshotGap;

  /// Forgets everything (new load).
  void beginLoad() {
    _position = null;
    _lastAt = null;
    _advancing = false;
    _advancingSince = null;
    _quality = null;
    _nativePosition = null;
    _nativeTime = null;
    _anchorNativeTime = null;
    _anchorSnapshotGap = null;
  }

  /// Integrates up to [at], then records the new player state and report.
  void onPlayerEvent({
    required bool advancing,
    required Duration updatePosition,
    required DateTime updateTime,
    required DateTime at,
  }) {
    advanceTo(at);
    if (advancing && !_advancing) _advancingSince = at;
    if (!advancing) _advancingSince = null;
    _advancing = advancing;
    _nativePosition = updatePosition;
    _nativeTime = updateTime;
  }

  /// Integrates media time up to [now] and walks it into the right segment.
  void advanceTo(DateTime now) {
    final pos = _position;
    final last = _lastAt;
    _lastAt = now;
    if (pos == null || last == null) return;
    final elapsed = _advancing ? _seconds(now.difference(last)) : 0.0;
    _position = _walk(pos.seq, pos.offset + (elapsed < 0 ? 0 : elapsed));
  }

  /// The playhead at [now], or null until anchored.
  HlsMediaPosition? positionAt(DateTime now) {
    final pos = _position;
    final last = _lastAt;
    if (pos == null || last == null) return null;
    final elapsed = _advancing ? _seconds(now.difference(last)) : 0.0;
    return _walk(pos.seq, pos.offset + (elapsed < 0 ? 0 : elapsed));
  }

  /// Settle-then-anchor; returns true when it (re)anchored.
  ///
  /// Needs [settle] of continuous playing && ready. Anchors exactly on the
  /// snapshot nearest the latest report when it is within [snapshotMatch];
  /// otherwise, once [projectAfter] passed without any anchor, projects
  /// from the nearest snapshot.
  bool tryAnchor(DateTime now, List<HlsPlaylistSnapshot> snapshots) {
    final since = _advancingSince;
    final reportAt = _nativeTime;
    final reported = _nativePosition;
    if (_quality == HlsAnchorQuality.exact || !_advancing) return false;
    if (since == null || reportAt == null || reported == null) return false;
    if (snapshots.isEmpty || reportAt == _anchorNativeTime) return false;
    final ranFor = now.difference(since);
    if (ranFor < settle) return false;
    final nearest = _nearest(snapshots, reportAt);
    final gap = nearest.fetchedAt.difference(reportAt);
    final position = _seconds(reported);
    if (gap.abs() <= snapshotMatch) {
      _anchor(nearest.locate(position), now, since, HlsAnchorQuality.exact,
          gap.abs());
      return true;
    }
    if (_quality != null || ranFor < projectAfter) return false;
    // The window slides with wall time, so the report is that much further
    // from the start of a window fetched later.
    _anchor(nearest.locate(position - _seconds(gap)), now, since,
        HlsAnchorQuality.projected, gap.abs());
    return true;
  }

  void _anchor(HlsMediaPosition at, DateTime now, DateTime since,
      HlsAnchorQuality quality, Duration snapshotGap) {
    final reportAt = _nativeTime!;
    // The report holds until playback started advancing.
    final from = reportAt.isAfter(since) ? reportAt : since;
    final elapsed = _seconds(now.difference(from));
    _position = _walk(at.seq, at.offset + (elapsed < 0 ? 0 : elapsed));
    _lastAt = now;
    _quality = quality;
    _anchorNativeTime = reportAt;
    _anchorSnapshotGap = snapshotGap;
  }

  /// Carries [offset] past segment ends while the next segment is known.
  HlsMediaPosition _walk(int seq, double offset) {
    var s = seq;
    var o = offset;
    while (true) {
      final entry = _ledger[s];
      if (entry == null || o < entry.duration || _ledger[s + 1] == null) {
        return HlsMediaPosition(s, o);
      }
      o -= entry.duration;
      s++;
    }
  }

  static HlsPlaylistSnapshot _nearest(
      List<HlsPlaylistSnapshot> snapshots, DateTime t) {
    var best = snapshots.first;
    for (final s in snapshots) {
      if (s.fetchedAt.difference(t).abs() <
          best.fetchedAt.difference(t).abs()) {
        best = s;
      }
    }
    return best;
  }

  static double _seconds(Duration d) => d.inMicroseconds / 1e6;
}
