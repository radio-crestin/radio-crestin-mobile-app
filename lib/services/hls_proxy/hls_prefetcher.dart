import 'dart:async';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import 'hls_cache.dart';

/// Polls the origin HLS playlist on an interval and proactively fetches
/// upcoming `.ts` segments into [HlsCache] before AVPlayer asks for them.
///
/// Lifecycle: created in [HlsProxyServer.bind] for one origin URL, started
/// when the proxy is asked to serve that station, stopped (via [stop]) on
/// station switch / playback stop / dispose.
///
/// Resilience: a single failed playlist or segment fetch never aborts the
/// loop. The next tick will retry. As long as iOS hasn't suspended the
/// Dart isolate (we keep that alive via the silence keeper while
/// buffering), prefetcher activity continues through transient network
/// loss.
class HlsPrefetcher {
  HlsPrefetcher({
    required this.originUrl,
    required this.cache,
    this.playlistInterval = const Duration(seconds: 3),
    this.client,
  });

  final String originUrl;
  final HlsCache cache;
  final Duration playlistInterval;
  final http.Client? client;

  Timer? _timer;
  bool _stopped = false;
  bool _tickInFlight = false;
  http.Client get _http => client ?? http.Client();

  Uri get _originUri => Uri.parse(originUrl);
  Uri get _segmentBaseUri => _originUri.resolve('.');

  Future<void> start() async {
    if (_timer != null) return;
    _stopped = false;
    // Kick off an immediate first tick so the cache is populated by the
    // time AVPlayer's first request lands on the proxy.
    unawaited(_tick());
    _timer = Timer.periodic(playlistInterval, (_) {
      if (!_stopped) unawaited(_tick());
    });
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_tickInFlight) return; // Coalesce overlapping ticks.
    _tickInFlight = true;
    try {
      await _refreshPlaylistAndPrefetch();
    } catch (e) {
      _log('tick failed: $e');
    } finally {
      _tickInFlight = false;
    }
  }

  Future<void> _refreshPlaylistAndPrefetch() async {
    final body = await _fetchOriginPlaylist();
    if (body == null) return;
    final segments = _extractSegmentFilenames(body);
    cache.putPlaylist(_rewritePlaylist(body));

    // Fetch any segments referenced in the playlist that we don't have.
    // Newest-first: AVPlayer wants the live edge.
    for (final filename in segments.reversed) {
      if (_stopped) return;
      if (cache.hasSegment(filename)) continue;
      await _fetchSegment(filename);
    }
  }

  Future<String?> _fetchOriginPlaylist() async {
    try {
      final resp = await _http.get(_originUri).timeout(
            const Duration(seconds: 5),
          );
      if (resp.statusCode != 200) {
        _log('playlist fetch ${resp.statusCode}');
        return null;
      }
      return resp.body;
    } catch (e) {
      _log('playlist fetch error: $e');
      return null;
    }
  }

  Future<void> _fetchSegment(String filename) async {
    final segUri = _segmentBaseUri.resolve(filename);
    try {
      final resp = await _http.get(segUri).timeout(
            const Duration(seconds: 8),
          );
      if (resp.statusCode != 200) {
        _log('segment $filename ${resp.statusCode}');
        return;
      }
      cache.putSegment(filename, resp.bodyBytes);
    } catch (e) {
      _log('segment $filename error: $e');
    }
  }

  /// Extract `.ts` filenames in playlist order. We don't strip EXTINF or
  /// other tags — we just want segment URIs (always plain paths in our
  /// own playlists; if a future origin uses absolute URLs we'd need to
  /// normalise).
  static List<String> _extractSegmentFilenames(String body) {
    return body
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.endsWith('.ts'))
        .toList(growable: false);
  }

  /// Rewrite the playlist so AVPlayer fetches segments from our proxy
  /// instead of the origin. Segment lines are already plain filenames
  /// (e.g. `1777713357.ts`); the proxy serves them at the same path,
  /// so the rewrite is a no-op in the common case. We still pass the
  /// playlist through so future origin formats (absolute URLs, query
  /// strings) get normalised here in one place.
  static String _rewritePlaylist(String body) {
    final out = StringBuffer();
    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.endsWith('.ts')) {
        // Strip any path/query — proxy serves under the playlist's directory.
        final uri = Uri.tryParse(trimmed);
        final filename = uri?.pathSegments.isNotEmpty == true
            ? uri!.pathSegments.last
            : trimmed;
        out.writeln(filename);
      } else {
        out.writeln(line);
      }
    }
    return out.toString();
  }

  static void _log(String msg) {
    developer.log(msg, name: 'HlsPrefetcher');
  }
}
