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

    Future<shelf.Response> handler(shelf.Request req) async {
      final segments = req.url.pathSegments;
      if (segments.isEmpty) {
        return shelf.Response.notFound('not found');
      }
      final last = segments.last;
      if (last.endsWith('.m3u8')) {
        return _serveM3u8(cache);
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

  static shelf.Response _serveM3u8(HlsCache cache) {
    final body = cache.playlist;
    if (body == null) {
      // Cold-start: prefetcher hasn't populated yet. AVPlayer will retry.
      return shelf.Response(503, body: 'playlist not ready');
    }
    return shelf.Response.ok(
      body,
      headers: {
        'Content-Type': 'application/vnd.apple.mpegurl',
        'Cache-Control': 'no-store',
      },
    );
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
