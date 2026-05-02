import 'dart:typed_data';

/// In-memory cache for the rewritten m3u8 + recently-fetched .ts segments.
///
/// Keyed by segment filename (e.g. `1777713357.ts`) for `.ts` lookups, and
/// stores a single `playlist` blob for the m3u8.
///
/// Eviction: bounded by [maxSegmentBytes] (FIFO by insertion order). At
/// ~96 kbps stereo with 6s segments, each `.ts` is ~70–80 KB; 1.5 MB
/// holds ~20 segments ≈ 2 minutes of audio.
class HlsCache {
  HlsCache({this.maxSegmentBytes = 1500000});

  final int maxSegmentBytes;

  String? _playlistBody;
  DateTime? _playlistFetchedAt;

  // LinkedHashMap preserves insertion order, used for FIFO eviction.
  final Map<String, Uint8List> _segments = <String, Uint8List>{};
  int _currentSegmentBytes = 0;

  String? get playlist => _playlistBody;
  DateTime? get playlistFetchedAt => _playlistFetchedAt;

  void putPlaylist(String body) {
    _playlistBody = body;
    _playlistFetchedAt = DateTime.now();
  }

  Uint8List? getSegment(String filename) => _segments[filename];

  bool hasSegment(String filename) => _segments.containsKey(filename);

  void putSegment(String filename, Uint8List bytes) {
    if (_segments.containsKey(filename)) {
      _currentSegmentBytes -= _segments[filename]!.length;
    }
    _segments[filename] = bytes;
    _currentSegmentBytes += bytes.length;
    _evictIfNeeded();
  }

  void _evictIfNeeded() {
    while (_currentSegmentBytes > maxSegmentBytes && _segments.length > 1) {
      // Drop the oldest segment (insertion order).
      final oldest = _segments.keys.first;
      _currentSegmentBytes -= _segments[oldest]!.length;
      _segments.remove(oldest);
    }
  }

  /// Approximate audio duration currently buffered. Useful for diagnostics.
  /// Assumes ~6s/segment (close enough — we don't parse EXTINF here).
  Duration get bufferedDuration => Duration(seconds: _segments.length * 6);

  int get segmentCount => _segments.length;
  int get totalBytes => _currentSegmentBytes;

  void clear() {
    _playlistBody = null;
    _playlistFetchedAt = null;
    _segments.clear();
    _currentSegmentBytes = 0;
  }
}
