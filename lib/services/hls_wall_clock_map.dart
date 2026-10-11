import 'dart:math' as math;

import 'hls_playlist_snapshot.dart';

/// Maps the encoder's PROGRAM-DATE-TIME clock onto the server wall clock.
///
/// ffmpeg stamps PDT as process-start time + media duration, so per station
/// it is off by -4531…+126 s (measured). The playlist's Last-Modified is the
/// server wall clock of the rewrite that published the newest segment (or a
/// later metadata-only rewrite), so the smallest `Last-Modified - liveEdgePdt`
/// over a few polls is the segment-close skew σ; +0.5 s centres the 1 s
/// HTTP-date truncation.
///
/// [sampleCount] is 4 because a 10 s poll against 6 s segments repeats its
/// phase every 30 s (3 polls): four samples always contain a whole cycle, so
/// the minimum converges by the 3rd poll.
///
/// σ is kept per *epoch*. Every sample is an upper bound of the true skew,
/// so within an epoch the minimum only falls (warm-up). An upstream stall on
/// today's backend shifts σ up by the stall length for the segments
/// published after it, and a minimum would never follow that. When the two
/// newest samples both sit more than [stepThresholdSeconds] above the
/// minimum, a new epoch starts from them; segments already published keep
/// the previous epoch's σ (see `HlsSegmentLedger`).
class HlsWallClockMap {
  static const int sampleCount = 4;

  /// A rise of both newest samples by more than this is a skew step, not
  /// rewrite jitter (measured Last-Modified lag: +0…+6 s, rarely two in a
  /// row above +2 s).
  static const double stepThresholdSeconds = 2.0;

  /// Centres the whole-second truncation of HTTP dates.
  static const double httpDateCentering = 0.5;

  /// Frozen epochs remembered. The segment ledger spans at most ~30 min.
  static const int maxFrozenEpochs = 16;

  final List<double> _samples = [];
  final Map<int, double> _frozen = {};
  int _epoch = 0;
  int _acceptedSamples = 0;
  String? _lastEdgeUri;

  /// Current epoch: segments first seen now belong to it.
  int get epoch => _epoch;

  /// Index of the newest accepted sample, -1 before the first.
  int get latestSample => _acceptedSamples - 1;

  /// σ of the current epoch (seconds), null before the first sample.
  double? get skewSeconds => sigmaFor(_epoch);

  /// σ of [epoch]; an unknown (pruned) epoch falls back to the current one.
  double? sigmaFor(int epoch) {
    if (epoch != _epoch) {
      final frozen = _frozen[epoch];
      if (frozen != null) return frozen;
    }
    return _samples.isEmpty ? null : _samples.reduce(math.min);
  }

  /// Feeds one snapshot.
  ///
  /// A snapshot whose newest segment was already sampled is skipped: a later
  /// Last-Modified of the same edge only measures a metadata rewrite, and
  /// during an origin stall it would push the real samples out of the
  /// window. Returns the first sample index of a new epoch when this sample
  /// completed a step, else null.
  int? add(HlsPlaylistSnapshot s) {
    final edgeUri = s.segments.last.uri;
    if (edgeUri == _lastEdgeUri) return null;
    _lastEdgeUri = edgeUri;
    _samples.add(_sampleOf(s));
    _acceptedSamples++;
    if (_samples.length > sampleCount) _samples.removeAt(0);
    return _detectStep() ? latestSample - 1 : null;
  }

  /// Starts a new epoch without a sample: the PDT domain itself changed
  /// (the backend re-dated published segments), so samples of the new
  /// domain must not move the σ of segments measured in the old one.
  void startEpoch() {
    final current = skewSeconds;
    if (current != null) _frozen[_epoch] = current;
    _frozen.removeWhere((e, _) => e <= _epoch - maxFrozenEpochs);
    _epoch++;
    _samples.clear();
    _lastEdgeUri = null;
  }

  void reset() {
    _samples.clear();
    _frozen.clear();
    _epoch = 0;
    _acceptedSamples = 0;
    _lastEdgeUri = null;
  }

  static double _sampleOf(HlsPlaylistSnapshot s) {
    final lm = s.lastModified;
    final edge = s.liveEdgePdt;
    if (lm == null) {
      // The device clock includes its own offset from the server; phones are
      // NTP-synced, so this is acceptable as a fallback only.
      return s.fetchedAt.microsecondsSinceEpoch / 1e6 - edge;
    }
    return lm.microsecondsSinceEpoch / 1e6 - edge + httpDateCentering;
  }

  bool _detectStep() {
    if (_samples.length < 3) return false;
    final n = _samples.length;
    final older = _samples.sublist(0, n - 2).reduce(math.min);
    final rose = _samples[n - 1] > older + stepThresholdSeconds &&
        _samples[n - 2] > older + stepThresholdSeconds;
    if (!rose) return false;
    _frozen[_epoch] = older;
    _frozen.removeWhere((e, _) => e <= _epoch - maxFrozenEpochs);
    _epoch++;
    _samples.removeRange(0, n - 2);
    return true;
  }
}
