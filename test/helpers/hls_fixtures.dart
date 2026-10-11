import 'dart:io';

import 'package:radio_crestin/services/hls_timeline.dart';

/// Wall-clock instant for [seconds] since the epoch (UTC).
DateTime at(double seconds) =>
    DateTime.fromMicrosecondsSinceEpoch((seconds * 1e6).round(), isUtc: true);

/// Seconds since the epoch of [t].
double secondsOf(DateTime t) => t.microsecondsSinceEpoch / 1e6;

/// Reads a fixture under `test/fixtures/`.
String readFixture(String relativePath) =>
    File('test/fixtures/$relativePath').readAsStringSync();

/// A live playlist window of equal segments, as recorded by the probe
/// (`seq`, first PDT [w0], window length [windowSeconds]).
///
/// Segment URIs are derived from the sequence number, so the same segment
/// keeps its URI across snapshots. [lastModified] is the HTTP
/// Last-Modified in epoch seconds (whole seconds, like an HTTP date).
HlsPlaylistSnapshot windowSnapshot({
  required int seq,
  required double w0,
  required double windowSeconds,
  required double fetchedAt,
  double? lastModified,
  double targetDuration = 6,
  String uriPrefix = 'seg',
  List<SongBoundary> boundaries = const [],
}) {
  final count = (windowSeconds / targetDuration).round().clamp(1, 1 << 20);
  final duration = windowSeconds / count;
  return HlsPlaylistSnapshot(
    segments: [
      for (var i = 0; i < count; i++)
        HlsSegmentRef(
          seq: seq + i,
          uri: '$uriPrefix-${seq + i}.ts',
          pdt: w0 + i * duration,
          duration: duration,
        ),
    ],
    mediaSequence: seq,
    targetDuration: targetDuration,
    fetchedAt: at(fetchedAt),
    lastModified: lastModified == null ? null : at(lastModified),
    songBoundaries: boundaries,
  );
}

/// Media-playlist text with [count] segments of [duration] seconds starting
/// at [firstPdt], for parser tests. [header] lines go after the standard
/// header, [beforeSegment] maps a segment index to extra lines emitted just
/// before it.
String playlistText({
  int mediaSequence = 100,
  int count = 3,
  double duration = 6.0,
  DateTime? firstPdt,
  List<String> header = const [],
  Map<int, List<String>> beforeSegment = const {},
  bool pdtOnEverySegment = true,
  String lineEnd = '\n',
}) {
  final start = firstPdt ?? DateTime.utc(2026, 10, 11, 10, 0, 0);
  final lines = <String>[
    '#EXTM3U',
    '#EXT-X-VERSION:6',
    '#EXT-X-TARGETDURATION:6',
    '#EXT-X-MEDIA-SEQUENCE:$mediaSequence',
    ...header,
  ];
  for (var i = 0; i < count; i++) {
    lines.addAll(beforeSegment[i] ?? const []);
    lines.add('#EXTINF:${duration.toStringAsFixed(6)},');
    if (pdtOnEverySegment || i == 0) {
      final pdt =
          start.add(Duration(microseconds: (i * duration * 1e6).round()));
      lines.add('#EXT-X-PROGRAM-DATE-TIME:${_pdtText(pdt)}');
    }
    lines.add('seg-${mediaSequence + i}.ts');
  }
  return lines.join(lineEnd) + lineEnd;
}

String _pdtText(DateTime t) {
  final iso = t.toUtc().toIso8601String(); // 2026-10-11T10:00:00.000Z
  return '${iso.substring(0, 23)}+0000';
}
