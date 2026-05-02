import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'hls_cache.dart';
import 'hls_prefetcher.dart';

/// Local HTTP server that fronts a single live HLS station, backed by an
/// [HlsCache] kept warm by an [HlsPrefetcher]. AVPlayer connects to
/// `http://127.0.0.1:<port>/index.m3u8`; we serve the cached playlist and
/// segments. On a segment cache miss we fall back to fetching from origin
/// inline (keeps playback working during the cold-start window before the
/// prefetcher has populated the cache).
///
/// Single-station design — switching stations stops the current proxy and
/// starts a fresh one, mirroring the simple cache. Keeps the surface
/// small; we can pool later if needed.
class HlsProxyServer {
  HlsProxyServer._({
    required this.port,
    required this.localUrl,
    required this.originUrl,
    required this.cache,
    required this.prefetcher,
    required HttpServer server,
    required http.Client httpClient,
  })  : _server = server,
        _httpClient = httpClient;

  final int port;
  final String localUrl;
  final String originUrl;
  final HlsCache cache;
  final HlsPrefetcher prefetcher;
  final HttpServer _server;
  final http.Client _httpClient;

  static HlsProxyServer? _current;

  /// Returns the currently-running proxy, if any.
  static HlsProxyServer? get current => _current;

  /// Tear down any running proxy and start a fresh one fronting [originUrl].
  /// Returns the local URL AVPlayer should connect to.
  static Future<HlsProxyServer> start(String originUrl) async {
    await stopCurrent();

    final cache = HlsCache();
    final httpClient = http.Client();
    final prefetcher = HlsPrefetcher(
      originUrl: originUrl,
      cache: cache,
      client: httpClient,
    );

    final originUri = Uri.parse(originUrl);
    final originBase = originUri.resolve('.');

    final originUriCaptured = originUri;
    Future<shelf.Response> handler(shelf.Request req) async {
      final segments = req.url.pathSegments;
      if (segments.isEmpty) {
        return shelf.Response.notFound('not found');
      }
      final last = segments.last;
      if (last.endsWith('.m3u8')) {
        return _serveM3u8(
          cache: cache,
          originUri: originUriCaptured,
          httpClient: httpClient,
        );
      }
      if (last.endsWith('.ts')) {
        return _serveSegment(
          filename: last,
          cache: cache,
          originBase: originBase,
          httpClient: httpClient,
        );
      }
      return shelf.Response.notFound('not found');
    }

    // Port 0 → OS picks a free port. Bind to loopback only.
    final server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final localUrl = 'http://127.0.0.1:$port/index.m3u8';

    _log('started on $localUrl, fronting $originUrl');

    final proxy = HlsProxyServer._(
      port: port,
      localUrl: localUrl,
      originUrl: originUrl,
      cache: cache,
      prefetcher: prefetcher,
      server: server,
      httpClient: httpClient,
    );
    _current = proxy;
    // Pre-warm: fetch the playlist + a few latest segments INLINE before
    // returning. Without this AVPlayer hits the proxy while the cache is
    // empty, our /index.m3u8 returns 503, and AVPlayer surfaces that as
    // -1008 NSURLErrorResourceUnavailable rather than retrying — so HLS
    // load fails on every cold start and we fall back to direct_stream.
    // Best-effort with a 5s timeout: if origin is unreachable we still
    // return so AVPlayer's own load attempt can produce a real error
    // (rather than waiting here indefinitely).
    try {
      await prefetcher.warmup(timeout: const Duration(seconds: 5));
    } catch (e) {
      _log('warmup failed (continuing): $e');
    }
    await prefetcher.start();
    return proxy;
  }

  /// Stop and clean up the currently-running proxy. Idempotent.
  static Future<void> stopCurrent() async {
    final existing = _current;
    if (existing == null) return;
    _current = null;
    try {
      existing.prefetcher.stop();
      existing._httpClient.close();
      await existing._server.close(force: true);
      existing.cache.clear();
      _log('stopped (was on :${existing.port})');
    } catch (e) {
      _log('stop error: $e');
    }
  }

  static Future<shelf.Response> _serveM3u8({
    required HlsCache cache,
    required Uri originUri,
    required http.Client httpClient,
  }) async {
    final cached = cache.playlist;
    if (cached != null) {
      return shelf.Response.ok(
        cached,
        headers: {
          'Content-Type': 'application/vnd.apple.mpegurl',
          'Cache-Control': 'no-store',
        },
      );
    }
    // Cache miss → fetch from origin inline so AVPlayer never sees a 503
    // (which it surfaces as -1008 and gives up on the HLS source). The
    // prefetcher will populate the cache shortly after start(), but
    // AVPlayer's first request can race the warmup; this is the safety
    // net.
    try {
      final resp = await httpClient.get(originUri).timeout(
            const Duration(seconds: 5),
          );
      if (resp.statusCode != 200) {
        return shelf.Response(resp.statusCode, body: 'origin ${resp.statusCode}');
      }
      final rewritten = _rewritePlaylistInline(resp.body);
      cache.putPlaylist(rewritten);
      return shelf.Response.ok(
        rewritten,
        headers: {
          'Content-Type': 'application/vnd.apple.mpegurl',
          'Cache-Control': 'no-store',
        },
      );
    } catch (e) {
      _log('m3u8 passthrough failed: $e');
      return shelf.Response(503, body: 'origin unreachable');
    }
  }

  /// Inline copy of HlsPrefetcher's playlist rewrite. Kept duplicated so
  /// the proxy can serve cold-start passthroughs without reaching into
  /// the prefetcher's internals.
  static String _rewritePlaylistInline(String body) {
    final out = StringBuffer();
    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.endsWith('.ts')) {
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

  static Future<shelf.Response> _serveSegment({
    required String filename,
    required HlsCache cache,
    required Uri originBase,
    required http.Client httpClient,
  }) async {
    final cached = cache.getSegment(filename);
    if (cached != null) {
      return shelf.Response.ok(
        cached,
        headers: {
          'Content-Type': 'video/mp2t',
          'Cache-Control': 'no-store',
          'Content-Length': '${cached.length}',
        },
      );
    }
    // Cache miss → fetch inline + populate cache, so a near-future request
    // is hot. This is the path during cold-start before the prefetcher has
    // caught up; in steady state every segment AVPlayer asks for is
    // already cached.
    try {
      final segUri = originBase.resolve(filename);
      final resp = await httpClient.get(segUri).timeout(
            const Duration(seconds: 8),
          );
      if (resp.statusCode != 200) {
        return shelf.Response(resp.statusCode, body: 'origin ${resp.statusCode}');
      }
      cache.putSegment(filename, resp.bodyBytes);
      return shelf.Response.ok(
        resp.bodyBytes,
        headers: {
          'Content-Type': 'video/mp2t',
          'Cache-Control': 'no-store',
          'Content-Length': '${resp.bodyBytes.length}',
        },
      );
    } catch (e) {
      _log('segment passthrough $filename failed: $e');
      return shelf.Response(503, body: 'origin unreachable');
    }
  }

  static void _log(String msg) {
    developer.log(msg, name: 'HlsProxyServer');
  }
}
