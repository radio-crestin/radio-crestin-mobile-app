import 'dart:io' show HttpDate, HttpException;

import 'song_boundary_queue.dart';

/// One media segment of a live HLS playlist.
class HlsSegmentRef {
  /// Media sequence number: `EXT-X-MEDIA-SEQUENCE` + index in the playlist.
  final int seq;
  final String uri;

  /// `EXT-X-PROGRAM-DATE-TIME` in the encoder's clock (seconds since epoch).
  final double pdt;

  /// `EXTINF` (seconds).
  final double duration;

  const HlsSegmentRef({
    required this.seq,
    required this.uri,
    required this.pdt,
    required this.duration,
  });

  double get end => pdt + duration;
}

/// A point in the media: [offset] seconds into segment [seq].
class HlsMediaPosition {
  final int seq;
  final double offset;

  const HlsMediaPosition(this.seq, this.offset);

  @override
  bool operator ==(Object other) =>
      other is HlsMediaPosition && other.seq == seq && other.offset == offset;

  @override
  int get hashCode => Object.hash(seq, offset);

  @override
  String toString() => 'HlsMediaPosition($seq + ${offset}s)';
}

/// One fetch of a live HLS media playlist, reduced to what the playback
/// timeline needs.
///
/// PDT values stay in the encoder's clock: they are only compared with other
/// PDT values of the same segment, or mapped through the wall-clock skew
/// estimator.
class HlsPlaylistSnapshot {
  final List<HlsSegmentRef> segments;
  final int mediaSequence;

  /// `EXT-X-TARGETDURATION` (seconds).
  final double targetDuration;

  /// HTTP `Last-Modified`: the server wall clock of the rewrite that
  /// published this version.
  final DateTime? lastModified;

  /// Local clock when the body arrived.
  final DateTime fetchedAt;

  /// `EXT-X-RC-METADATA-CHANGED` `EPOCH`: when the current song started.
  final DateTime? metadataChangedAt;

  /// Every announced song change (METADATA-CHANGED, DATERANGE start/end).
  final List<SongBoundary> songBoundaries;

  const HlsPlaylistSnapshot({
    required this.segments,
    required this.mediaSequence,
    required this.targetDuration,
    required this.fetchedAt,
    this.lastModified,
    this.metadataChangedAt,
    this.songBoundaries = const [],
  });

  int get firstSeq => segments.first.seq;
  int get lastSeq => segments.last.seq;
  double get windowStartPdt => segments.first.pdt;
  double get liveEdgePdt => segments.last.end;

  double get windowSeconds => segments.fold(0.0, (sum, s) => sum + s.duration);

  /// The media position [offset] seconds after the window start, walking
  /// the segment durations (exact even when PDT steps differ from EXTINF).
  ///
  /// Clamped to the window. A position exactly on a segment edge belongs to
  /// the next segment.
  HlsMediaPosition locate(double offset) {
    var remaining = offset < 0 ? 0.0 : offset;
    for (final s in segments) {
      if (remaining < s.duration) return HlsMediaPosition(s.seq, remaining);
      remaining -= s.duration;
    }
    final last = segments.last;
    return HlsMediaPosition(last.seq, last.duration);
  }

  /// Parses a media playlist body.
  ///
  /// Returns null for anything the timeline cannot use: no `#EXTM3U`, no
  /// segments, or no `EXT-X-PROGRAM-DATE-TIME` at all (see
  /// [isMediaPlaylistWithoutPdt]).
  static HlsPlaylistSnapshot? parse(
    String body, {
    required DateTime fetchedAt,
    String? lastModifiedHeader,
  }) {
    final parser = _PlaylistParser();
    if (!parser.run(body)) return null;
    final segments = parser.buildSegments();
    if (segments == null) return null;
    return HlsPlaylistSnapshot(
      segments: segments,
      mediaSequence: parser.mediaSequence,
      targetDuration: parser.targetDuration,
      fetchedAt: fetchedAt,
      lastModified: _parseHttpDate(lastModifiedHeader),
      metadataChangedAt: parser.metadataChangedAt,
      songBoundaries: parser.boundaries,
    );
  }

  /// True for a valid media playlist that carries no PROGRAM-DATE-TIME. The
  /// timeline can then only approximate the audible instant.
  static bool isMediaPlaylistWithoutPdt(String body) {
    final parser = _PlaylistParser();
    return parser.run(body) &&
        parser.uris.isNotEmpty &&
        parser.pdts.every((p) => p == null);
  }

  static DateTime? _parseHttpDate(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    try {
      return HttpDate.parse(header.trim());
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }
}

/// Parses an RFC 8216 §4.2 attribute list (`NAME=value,NAME="quoted, value"`).
///
/// Quoted strings may contain commas and `=`, so the list is scanned rather
/// than split. Quotes are stripped from the returned values. The first
/// occurrence of a name wins. Malformed trailing input is ignored.
Map<String, String> parseHlsAttributeList(String text) {
  final result = <String, String>{};
  var i = 0;
  while (i < text.length) {
    final eq = text.indexOf('=', i);
    if (eq < 0) break;
    final name = text.substring(i, eq).trim();
    i = eq + 1;
    String value;
    if (i < text.length && text[i] == '"') {
      final close = text.indexOf('"', i + 1);
      if (close < 0) break; // unterminated quoted string
      value = text.substring(i + 1, close);
      i = close + 1;
      final comma = text.indexOf(',', i);
      i = comma < 0 ? text.length : comma + 1;
    } else {
      final comma = text.indexOf(',', i);
      final end = comma < 0 ? text.length : comma;
      value = text.substring(i, end).trim();
      i = end + 1;
    }
    if (name.isNotEmpty) result.putIfAbsent(name, () => value);
  }
  return result;
}

/// Line-by-line state of one playlist parse.
class _PlaylistParser {
  static const _pdtTag = '#EXT-X-PROGRAM-DATE-TIME:';
  static const _infTag = '#EXTINF:';
  static const _metadataChangedTag = '#EXT-X-RC-METADATA-CHANGED:';
  static const _dateRangeTag = '#EXT-X-DATERANGE:';
  static const _targetTag = '#EXT-X-TARGETDURATION:';
  static const _sequenceTag = '#EXT-X-MEDIA-SEQUENCE:';

  int mediaSequence = 0;
  double targetDuration = 0;
  DateTime? metadataChangedAt;
  final List<SongBoundary> boundaries = [];
  final List<String> uris = [];
  final List<double?> durations = [];
  final List<double?> pdts = [];

  double? _pendingDuration;
  double? _pendingPdt;

  /// Returns false when the body is not an HLS playlist.
  bool run(String body) {
    final lines = body.split('\n').map((l) => l.trim());
    var sawHeader = false;
    for (final line in lines) {
      if (line.isEmpty) continue;
      if (!sawHeader) {
        if (line.replaceFirst('\uFEFF', '') != '#EXTM3U') return false;
        sawHeader = true;
        continue;
      }
      _consume(line);
    }
    return sawHeader;
  }

  void _consume(String line) {
    if (!line.startsWith('#')) {
      uris.add(line);
      durations.add(_pendingDuration);
      pdts.add(_pendingPdt);
      _pendingDuration = null;
      _pendingPdt = null;
    } else if (line.startsWith(_infTag)) {
      final value = line.substring(_infTag.length).split(',').first;
      _pendingDuration = double.tryParse(value.trim());
    } else if (line.startsWith(_pdtTag)) {
      final dt = DateTime.tryParse(line.substring(_pdtTag.length).trim());
      if (dt != null) _pendingPdt = dt.microsecondsSinceEpoch / 1e6;
    } else if (line.startsWith(_targetTag)) {
      targetDuration =
          double.tryParse(line.substring(_targetTag.length).trim()) ?? 0;
    } else if (line.startsWith(_sequenceTag)) {
      mediaSequence =
          int.tryParse(line.substring(_sequenceTag.length).trim()) ?? 0;
    } else if (line.startsWith(_metadataChangedTag)) {
      _onMetadataChanged(line.substring(_metadataChangedTag.length));
    } else if (line.startsWith(_dateRangeTag)) {
      _onDateRange(line.substring(_dateRangeTag.length));
    }
    // Every other tag (DISCONTINUITY, DISCONTINUITY-SEQUENCE, START,
    // INDEPENDENT-SEGMENTS, unknown custom tags) is irrelevant here.
  }

  void _onMetadataChanged(String attributes) {
    final attrs = parseHlsAttributeList(attributes);
    final epoch = int.tryParse(attrs['EPOCH'] ?? '');
    if (epoch == null) return;
    final at = DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
    metadataChangedAt = at;
    final hint = _hintFrom(attrs);
    boundaries.add(SongBoundary(at, hint: hint.isEmpty ? null : hint));
  }

  void _onDateRange(String attributes) {
    final attrs = parseHlsAttributeList(attributes);
    for (final key in const ['START-DATE', 'END-DATE']) {
      final at = DateTime.tryParse(attrs[key] ?? '');
      if (at != null) boundaries.add(SongBoundary(at.toUtc()));
    }
  }

  static SongBoundaryHint _hintFrom(Map<String, String> attrs) {
    String? text(String key) {
      final v = attrs[key]?.trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    final thumbnail = text('X-THUMBNAIL-URL');
    final isHttp = thumbnail != null &&
        (thumbnail.startsWith('https://') || thumbnail.startsWith('http://'));
    return SongBoundaryHint(
      title: text('X-TITLE'),
      artist: text('X-ARTIST'),
      songId: int.tryParse(attrs['X-SONG-ID']?.trim() ?? ''),
      artistId: int.tryParse(attrs['X-ARTIST-ID']?.trim() ?? ''),
      thumbnailUrl: isHttp ? thumbnail : null,
    );
  }

  /// Segments with resolved PDT and duration, or null when there are no
  /// segments or no PDT anywhere.
  ///
  /// A segment without its own PDT continues the previous one (PDT +
  /// EXTINF); segments before the first PDT are back-filled from it.
  List<HlsSegmentRef>? buildSegments() {
    if (uris.isEmpty) return null;
    final firstPdt = pdts.indexWhere((p) => p != null);
    if (firstPdt < 0) return null;
    final fallback = targetDuration > 0 ? targetDuration : 0.0;
    final dur = [for (final d in durations) d ?? fallback];
    final resolved = List<double>.filled(uris.length, 0);
    resolved[firstPdt] = pdts[firstPdt]!;
    for (var i = firstPdt - 1; i >= 0; i--) {
      resolved[i] = resolved[i + 1] - dur[i];
    }
    for (var i = firstPdt + 1; i < uris.length; i++) {
      resolved[i] = pdts[i] ?? resolved[i - 1] + dur[i - 1];
    }
    return [
      for (var i = 0; i < uris.length; i++)
        HlsSegmentRef(
          seq: mediaSequence + i,
          uri: uris[i],
          pdt: resolved[i],
          duration: dur[i],
        ),
    ];
  }
}
