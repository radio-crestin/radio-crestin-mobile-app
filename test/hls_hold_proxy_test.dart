import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/hls_hold_proxy.dart';

/// Real HTTP clients: a test binding fakes `HttpClient` globally.
class _RealHttp extends HttpOverrides {}

HttpClient _realHttpClient() =>
    HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());

/// A request the origin got.
class _Seen {
  _Seen(this.method, this.uri, HttpHeaders headers)
      : userAgent = headers.value('user-agent'),
        playbackSession = headers.value('x-playback-session-id'),
        range = headers.value('range'),
        acceptEncoding = headers.value('accept-encoding');

  final String method;
  final Uri uri;
  final String? userAgent;
  final String? playbackSession;
  final String? range;
  final String? acceptEncoding;
}

/// A fake origin on the loopback interface whose network can go away.
class _Origin {
  late final HttpServer _server;

  /// Every request it got, in order.
  final List<_Seen> requests = [];

  /// While set, every connection is cut before an answer: no network.
  bool offline = false;

  /// While set, every request is left unanswered, as on a network whose
  /// packets vanish (a tunnel): the client waits until its timeout.
  bool blackhole = false;

  /// The requests left unanswered, closed with the origin.
  final List<HttpRequest> _unanswered = [];

  /// The next this many requests get their connection cut.
  int dropNext = 0;

  /// The playlist's version, to tell a fresh answer from an old one.
  int version = 1;

  /// Answers in place of the default playlists and segments.
  Future<void> Function(HttpRequest request)? handler;

  int get port => _server.port;

  String url(String path) => 'http://127.0.0.1:$port$path';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve);
  }

  Future<void> close() async {
    for (final request in _unanswered) {
      try {
        (await request.response.detachSocket(writeHeaders: false)).destroy();
      } catch (_) {}
    }
    await _server.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    requests.add(_Seen(request.method, request.uri, request.headers));
    if (blackhole) {
      _unanswered.add(request);
      return;
    }
    if (offline || dropNext > 0) {
      if (dropNext > 0) dropNext--;
      (await request.response.detachSocket(writeHeaders: false)).destroy();
      return;
    }
    final handler = this.handler;
    if (handler != null) return handler(request);
    final response = request.response;
    if (request.uri.path.endsWith('.m3u8')) {
      response.headers
        ..contentType = ContentType('application', 'vnd.apple.mpegurl')
        ..set('cache-control', 'no-store')
        ..set('etag', 'W/"v$version"')
        ..set('last-modified', 'Sat, 17 Oct 2026 08:44:00 GMT');
      response.write(_playlist(version));
    } else {
      final bytes = utf8.encode('segment ${request.uri.path}');
      response.headers
        ..contentType = ContentType('video', 'mp2t')
        ..set('accept-ranges', 'bytes');
      final range = RegExp(r'bytes=(\d+)-(\d+)')
          .firstMatch(request.headers.value('range') ?? '');
      if (range != null) {
        final from = int.parse(range[1]!);
        final to = int.parse(range[2]!);
        response
          ..statusCode = 206
          ..headers.set('content-range', 'bytes $from-$to/${bytes.length}');
        response.add(bytes.sublist(from, to + 1));
      } else {
        response.contentLength = bytes.length;
        if (request.method != 'HEAD') response.add(bytes);
      }
    }
    await response.close();
  }
}

String _playlist(int version) => '#EXTM3U\n'
    '#EXT-X-VERSION:6\n'
    '#EXT-X-MEDIA-SEQUENCE:$version\n'
    '#EXTINF:6.0,\n'
    'seg-$version.ts\n';

/// What the client got: the status, the headers and the body.
class _Got {
  _Got(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final String body;
}

void main() {
  late _Origin origin;
  late HttpClient player;
  late HlsHoldProxy proxy;
  late List<HlsHoldProxyEvent> events;
  late bool offline;
  late StreamController<bool> offlineChanges;

  const fast = HlsHoldProxyTimings(
    retryInterval: Duration(milliseconds: 100),
    maxHold: Duration(seconds: 20),
    connectTimeout: Duration(seconds: 2),
    responseTimeout: Duration(seconds: 2),
    bodyIdleTimeout: Duration(seconds: 2),
  );

  /// A started proxy for [origin], fed the test's offline signal unless
  /// [withOfflineSignal] is false.
  Future<HlsHoldProxy> startProxy({
    HlsHoldProxyTimings timings = fast,
    bool withOfflineSignal = true,
    void Function(HlsHoldProxyEvent event)? onEvent,
  }) async {
    proxy = HlsHoldProxy(
      allowedHosts: const ['127.0.0.1'],
      httpClientFactory: _realHttpClient,
      isOffline: withOfflineSignal ? () => offline : null,
      offlineChanges: withOfflineSignal ? offlineChanges.stream : null,
      timings: timings,
      onEvent: onEvent ?? events.add,
    );
    expect(await proxy.start(), isTrue);
    return proxy;
  }

  /// The network goes away (origin and signal), or comes back.
  void setOffline(bool value) {
    origin.offline = value;
    offline = value;
    offlineChanges.add(value);
  }

  Future<_Got> get(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
  }) async {
    final request = await player.openUrl(method, Uri.parse(url));
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    return _Got(response.statusCode, response.headers, body);
  }

  /// A proxied playlist URL of [origin] in a new session, loaded once so
  /// that the session is established.
  Future<String> establishedPlaylist() async {
    final url = proxy.wrap(
        origin.url('/hls/rve/index-5m.m3u8?ref=app&s=d1'),
        proxy.beginSession())!;
    expect((await get(url)).status, 200);
    return url;
  }

  /// Whether [future] is still pending after [wait].
  Future<bool> stillPending(Future<Object?> future,
      {Duration wait = const Duration(milliseconds: 400)}) async {
    var done = false;
    future
        .then((_) => done = true, onError: (Object _) => done = true)
        .ignore();
    await Future<void>.delayed(wait);
    return !done;
  }

  Iterable<HlsHoldProxyEvent> eventsOf(HlsHoldProxyEventKind kind) =>
      events.where((e) => e.kind == kind);

  /// Waits until [condition] holds.
  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('condition not met in 5 s');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() async {
    origin = _Origin();
    await origin.start();
    player = _realHttpClient();
    events = [];
    offline = false;
    offlineChanges = StreamController<bool>.broadcast();
  });

  tearDown(() async {
    player.close(force: true);
    await proxy.stop();
    await origin.close();
    await offlineChanges.close();
  });

  group('relaying', () {
    test(
        'relays the origin\'s status, headers and body, keeps the query, and '
        'forwards the player\'s request headers', () async {
      await startProxy();
      final url = proxy.wrap(
          origin.url('/hls/rve/index-5m.m3u8?ref=radio-crestin-ios&s=d1'),
          proxy.beginSession())!;
      expect(url,
          startsWith('http://127.0.0.1:${proxy.port}/1/http/127.0.0.1:'));

      final got = await get(url, headers: {
        'user-agent': 'AppleCoreMedia/1.0.0',
        'x-playback-session-id': 'ABC-123',
      });

      expect(got.status, 200);
      expect(got.body, _playlist(1));
      expect(got.headers.contentType?.mimeType,
          'application/vnd.apple.mpegurl');
      expect(got.headers.value('cache-control'), 'no-store');
      expect(got.headers.value('etag'), 'W/"v1"');
      expect(got.headers.value('last-modified'),
          'Sat, 17 Oct 2026 08:44:00 GMT');
      expect(got.headers.contentLength, utf8.encode(_playlist(1)).length);
      final seen = origin.requests.single;
      expect(seen.uri.path, '/hls/rve/index-5m.m3u8');
      expect(seen.uri.query, 'ref=radio-crestin-ios&s=d1',
          reason: 'listeners are counted from these');
      expect(seen.userAgent, 'AppleCoreMedia/1.0.0');
      expect(seen.playbackSession, 'ABC-123');
      expect(events, hasLength(1), reason: 'only serverStarted: no log line '
          'per normal request');
    });

    test('a segment URI relative to the playlist resolves to the origin\'s '
        'path through the proxy', () async {
      await startProxy();
      final playlistUrl = await establishedPlaylist();

      final segmentUrl = Uri.parse(playlistUrl).resolve('seg-1.ts');
      final got = await get(segmentUrl.toString());

      expect(got.status, 200);
      expect(got.body, 'segment /hls/rve/seg-1.ts');
      expect(origin.requests.last.uri.path, '/hls/rve/seg-1.ts');
    });

    test('a gzip answer is decompressed: the player gets the plain body and '
        'its length', () async {
      await startProxy();
      origin.handler = (request) async {
        final body = gzip.encode(utf8.encode(_playlist(7)));
        request.response.headers
          ..contentType = ContentType('application', 'vnd.apple.mpegurl')
          ..set('content-encoding', 'gzip');
        request.response
          ..contentLength = body.length
          ..add(body);
        await request.response.close();
      };
      final url = proxy.wrap(
          origin.url('/hls/rve/index.m3u8'), proxy.beginSession())!;

      final request = await player.getUrl(Uri.parse(url));
      request.headers.set('accept-encoding', 'identity');
      final response = await request.close();
      final body = await utf8.decodeStream(response);

      expect(body, _playlist(7));
      expect(response.headers.value('content-encoding'), isNull);
      expect(response.headers.contentLength, utf8.encode(_playlist(7)).length);
      expect(origin.requests.single.acceptEncoding, 'gzip',
          reason: 'compressed upstream, where it costs');
    });

    test('HEAD and range requests get the lengths and ranges as stored',
        () async {
      await startProxy();
      final url = proxy.wrap(
          origin.url('/hls/rve/seg-1.ts'), proxy.beginSession())!;
      final length = utf8.encode('segment /hls/rve/seg-1.ts').length;

      final head = await get(url, method: 'HEAD');
      expect(head.status, 200);
      expect(head.body, isEmpty);
      expect(head.headers.contentLength, length);
      expect(origin.requests.last.acceptEncoding, 'identity');

      final range = await get(url, headers: {'range': 'bytes=0-6'});
      expect(range.status, 206);
      expect(range.body, 'segment');
      expect(range.headers.value('content-range'), 'bytes 0-6/$length');
      expect(range.headers.value('accept-ranges'), 'bytes');
      expect(origin.requests.last.range, 'bytes=0-6');
      expect(origin.requests.last.acceptEncoding, 'identity');
    });

    test('a body over the buffer limit is streamed whole', () async {
      await startProxy(
          timings: const HlsHoldProxyTimings(maxBufferedBytes: 1000));
      final big = List.generate(5000, (i) => 'abcdefghij'[i % 10]).join();
      origin.handler = (request) async {
        request.response.headers.contentType = ContentType('video', 'mp2t');
        for (var i = 0; i < big.length; i += 700) {
          request.response.write(big.substring(
              i, i + 700 > big.length ? big.length : i + 700));
          await request.response.flush();
        }
        await request.response.close();
      };
      final url =
          proxy.wrap(origin.url('/hls/rve/big.ts'), proxy.beginSession())!;

      final got = await get(url);

      expect(got.status, 200);
      expect(got.body, big);
    });

    test('a redirect to an allowed host stays on the proxy', () async {
      await startProxy();
      origin.handler = (request) async {
        request.response
          ..statusCode = 302
          ..headers.set('location', origin.url('/hls/other/index.m3u8?x=1'));
        await request.response.close();
      };
      final session = proxy.beginSession();
      final url = proxy.wrap(origin.url('/hls/rve/index.m3u8'), session)!;

      final request = await player.getUrl(Uri.parse(url));
      request.followRedirects = false;
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, 302);
      expect(response.headers.value('location'),
          '/$session/http/127.0.0.1:${origin.port}/hls/other/index.m3u8?x=1');
    });

    test('an unknown path gets a 404, another method a 405, another host '
        'is not fetched', () async {
      await startProxy();
      final base = 'http://127.0.0.1:${proxy.port}';

      expect((await get('$base/hls/rve/index.m3u8')).status, 404);
      expect((await get('$base/1/https/example.com/index.m3u8')).status, 404);
      final url =
          proxy.wrap(origin.url('/hls/rve/index.m3u8'), proxy.beginSession())!;
      expect((await get(url, method: 'POST')).status, 405);
      expect(origin.requests, isEmpty);
    });
  });

  group('HTTP errors', () {
    test('an error status is the origin answering: relayed at once, never '
        'held, also for the established session', () async {
      await startProxy();
      final playlistUrl = await establishedPlaylist();
      origin.handler = (request) async {
        request.response.statusCode =
            request.uri.path.endsWith('missing.ts') ? 404 : 503;
        request.response.write('nope');
        await request.response.close();
      };
      final base = Uri.parse(playlistUrl);

      final missing = await get(base.resolve('missing.ts').toString());
      final busy = await get(base.resolve('busy.m3u8').toString());

      expect(missing.status, 404);
      expect(missing.body, 'nope');
      expect(busy.status, 503);
      expect(eventsOf(HlsHoldProxyEventKind.holdStarted), isEmpty);
    });
  });

  group('holding through an outage', () {
    test(
        'holds a request of the established session and answers it with the '
        'fresh response the moment the internet is back', () async {
      // A long interval: only the offline signal can retry this soon.
      await startProxy(
          timings: const HlsHoldProxyTimings(
              retryInterval: Duration(seconds: 30)));
      final url = await establishedPlaylist();
      setOffline(true);
      origin.version = 2;

      final held = get(url);
      expect(await stillPending(held), isTrue);
      expect(eventsOf(HlsHoldProxyEventKind.holdStarted).single.resource,
          'index-5m.m3u8');

      final watch = Stopwatch()..start();
      setOffline(false);
      final got = await held;

      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(got.status, 200);
      expect(got.body, _playlist(2), reason: 'a fresh answer, not a replay');
      final end = eventsOf(HlsHoldProxyEventKind.holdEnded).single;
      expect(end.endReason, HlsHoldEnd.answered);
      expect(end.status, 200);
      expect(end.held, greaterThan(const Duration(milliseconds: 300)));
    });

    test('without an offline signal a held request retries on its interval',
        () async {
      await startProxy(withOfflineSignal: false);
      final url = await establishedPlaylist();
      origin.offline = true;

      final held = get(url);
      expect(await stillPending(held), isTrue);
      final triesWhileOffline = origin.requests.length;
      origin.offline = false;
      final got = await held;

      expect(got.status, 200);
      expect(triesWhileOffline, greaterThan(3), reason: 'retried every 100 ms');
      expect(eventsOf(HlsHoldProxyEventKind.holdEnded).single.endReason,
          HlsHoldEnd.answered);
    });

    test('a held segment loads once the network is back', () async {
      await startProxy();
      final url = await establishedPlaylist();
      setOffline(true);

      final held = get(Uri.parse(url).resolve('seg-1.ts').toString());
      expect(await stillPending(held), isTrue);
      setOffline(false);

      expect((await held).body, 'segment /hls/rve/seg-1.ts');
    });

    test('a request held while the listening socket closes is still answered',
        () async {
      await startProxy();
      final url = await establishedPlaylist();
      final port = proxy.port;
      setOffline(true);
      final held = get(url);
      expect(await stillPending(held), isTrue);

      await proxy.debugCloseServer();
      await until(() => !proxy.isRunning);
      expect(eventsOf(HlsHoldProxyEventKind.serverClosed), hasLength(1));
      setOffline(false);

      expect((await held).status, 200);
      expect(await proxy.ensureRunning(), isTrue);
      expect(proxy.port, port, reason: 'restarted on its own port');
      expect(proxy.serves(url), isTrue);
    });
  });

  group('failing fast', () {
    test('a new load while offline fails at once, as without the proxy',
        () async {
      await startProxy();
      setOffline(true);
      final url =
          proxy.wrap(origin.url('/hls/rve/index.m3u8'), proxy.beginSession())!;

      final watch = Stopwatch()..start();
      await expectLater(get(url), throwsA(isA<HttpException>()));

      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(eventsOf(HlsHoldProxyEventKind.failedFast), hasLength(1));
      expect(eventsOf(HlsHoldProxyEventKind.holdStarted), isEmpty);
    });

    test('a request of a replaced session fails at once', () async {
      await startProxy();
      final oldUrl = await establishedPlaylist();
      proxy.beginSession();
      setOffline(true);

      await expectLater(get(oldUrl), throwsA(isA<HttpException>()));
      expect(eventsOf(HlsHoldProxyEventKind.failedFast).single.session, 1);
    });

    test(
        'a connection that died in the pool is retried at once on a new one: '
        'a new load does not fail for it', () async {
      await startProxy();
      origin.dropNext = 1;
      final url =
          proxy.wrap(origin.url('/hls/rve/index.m3u8'), proxy.beginSession())!;

      final got = await get(url);

      expect(got.status, 200);
      expect(origin.requests, hasLength(2));
      expect(events.where((e) => e.kind != HlsHoldProxyEventKind.serverStarted),
          isEmpty);
    });
  });

  group('ending a hold', () {
    test('a new session releases the requests held for the old one', () async {
      await startProxy();
      final url = await establishedPlaylist();
      setOffline(true);
      final held = get(url);
      expect(await stillPending(held), isTrue);

      proxy.beginSession();

      await expectLater(held, throwsA(isA<HttpException>()));
      expect(eventsOf(HlsHoldProxyEventKind.holdEnded).single.endReason,
          HlsHoldEnd.released);
    });

    test('a hold ends after the longest hold', () async {
      await startProxy(
          timings: const HlsHoldProxyTimings(
              retryInterval: Duration(milliseconds: 100),
              maxHold: Duration(milliseconds: 700)));
      final url = await establishedPlaylist();
      setOffline(true);

      final watch = Stopwatch()..start();
      await expectLater(get(url), throwsA(isA<HttpException>()));

      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 600)));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      final end = eventsOf(HlsHoldProxyEventKind.holdEnded).single;
      expect(end.endReason, HlsHoldEnd.maxHold);
    });

    test(
        'the origin out of reach while the internet is known to work is '
        'held too: failing it would only make the player give up', () async {
      await startProxy();
      final url = await establishedPlaylist();
      origin.offline = true; // the origin alone: the internet stays up

      final held = get(url);
      expect(await stillPending(held, wait: const Duration(seconds: 1)),
          isTrue);
      expect(eventsOf(HlsHoldProxyEventKind.holdRetryFailed).length,
          greaterThan(3));
      origin.offline = false;

      expect((await held).status, 200);
      expect(eventsOf(HlsHoldProxyEventKind.holdEnded).single.endReason,
          HlsHoldEnd.answered);
    });

    test('a client that leaves ends its hold, and the retries stop',
        () async {
      await startProxy();
      final url = await establishedPlaylist();
      setOffline(true);
      final leaving = _realHttpClient();
      final held = leaving
          .getUrl(Uri.parse(url))
          .then((request) => request.close());
      expect(await stillPending(held), isTrue);

      leaving.close(force: true);
      await held.then((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final tries = origin.requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(eventsOf(HlsHoldProxyEventKind.holdEnded).single.endReason,
          HlsHoldEnd.clientGone);
      expect(origin.requests, hasLength(tries), reason: 'no more retries');
    });

    test('stopping the proxy fails the held requests', () async {
      await startProxy();
      final url = await establishedPlaylist();
      setOffline(true);
      final held = get(url);
      expect(await stillPending(held), isTrue);

      await proxy.stop();

      await expectLater(held, throwsA(isA<HttpException>()));
      expect(eventsOf(HlsHoldProxyEventKind.holdEnded).single.endReason,
          HlsHoldEnd.stopped);
    });
  });

  group('a network whose packets vanish', () {
    const hanging = HlsHoldProxyTimings(
      retryInterval: Duration(milliseconds: 100),
      maxHold: Duration(seconds: 20),
      connectTimeout: Duration(seconds: 2),
      responseTimeout: Duration(milliseconds: 1500),
      bodyIdleTimeout: Duration(seconds: 2),
    );

    test(
        'a retry left hanging is abandoned for a new one the moment the '
        'internet is back, instead of waiting out its timeout', () async {
      await startProxy(timings: hanging);
      final url = await establishedPlaylist();
      origin.blackhole = true;
      offline = true;
      offlineChanges.add(true);

      final held = get(url);
      // The first try and its retry at once time out: then it is held.
      await until(
          () => eventsOf(HlsHoldProxyEventKind.holdStarted).isNotEmpty);
      // A held retry is now hanging, for up to 1.5 s.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      origin.blackhole = false;
      final watch = Stopwatch()..start();
      offline = false;
      offlineChanges.add(false);

      expect((await held).status, 200);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 700)));
      expect(eventsOf(HlsHoldProxyEventKind.holdStarted).single.error,
          isA<TimeoutException>());
    });

    test(
        'without the offline signal, a retry left hanging ends at its '
        'response timeout and the next one gets through', () async {
      await startProxy(timings: hanging, withOfflineSignal: false);
      final url = await establishedPlaylist();
      origin.blackhole = true;

      final held = get(url);
      await until(
          () => eventsOf(HlsHoldProxyEventKind.holdStarted).isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      origin.blackhole = false;
      final watch = Stopwatch()..start();

      expect((await held).status, 200);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(
          eventsOf(HlsHoldProxyEventKind.holdRetryFailed)
              .map((e) => e.error),
          contains(isA<TimeoutException>()));
    });
  });

  group('a network change', () {
    test(
        'cuts a request in flight on the network left and sends it again at '
        'once on a new connection', () async {
      await startProxy(
          timings: const HlsHoldProxyTimings(
              responseTimeout: Duration(seconds: 10)));
      var first = true;
      origin.handler = (request) async {
        if (first) {
          // Lost with the network it went out on: never answered.
          first = false;
          return;
        }
        request.response.write('segment ${request.uri.path}');
        await request.response.close();
      };
      final url =
          proxy.wrap(origin.url('/hls/rve/seg-1.ts'), proxy.beginSession())!;

      final got = get(url);
      await until(() => origin.requests.isNotEmpty);
      final watch = Stopwatch()..start();
      proxy.networkChanged();

      expect((await got).body, 'segment /hls/rve/seg-1.ts');
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(origin.requests, hasLength(2));
    });

    test('retries a held request at once, on a new connection', () async {
      await startProxy(
          timings: const HlsHoldProxyTimings(
              retryInterval: Duration(seconds: 30)));
      final url = await establishedPlaylist();
      origin.offline = true;
      final held = get(url);
      await until(
          () => eventsOf(HlsHoldProxyEventKind.holdStarted).isNotEmpty);
      origin.offline = false;

      final watch = Stopwatch()..start();
      proxy.networkChanged();

      expect((await held).status, 200);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)),
          reason: 'not after the 30 s retry interval');
    });
  });

  group('whether the origin answered', () {
    test('a session is answered once a request of it got any response',
        () async {
      await startProxy();
      final session = proxy.beginSession();
      expect(proxy.originAnswered(session), isFalse);

      origin.offline = true;
      final url = proxy.wrap(origin.url('/hls/rve/index.m3u8'), session)!;
      await expectLater(get(url), throwsA(isA<HttpException>()));
      expect(proxy.originAnswered(session), isFalse,
          reason: 'failed before any answer');

      origin.offline = false;
      origin.handler = (request) async {
        request.response.statusCode = 404;
        await request.response.close();
      };
      expect((await get(url)).status, 404);
      expect(proxy.originAnswered(session), isTrue,
          reason: 'a status is an answer');

      final next = proxy.beginSession();
      expect(proxy.originAnswered(next), isFalse);
      expect(proxy.originAnswered(session), isFalse,
          reason: 'only the current session is followed');
    });
  });

  group('playlist URIs', () {
    test('rewrites the URI lines and URI attributes it is told to, keeping '
        'everything else', () {
      const playlist = '#EXTM3U\r\n'
          '#EXT-X-MAP:URI="/init.mp4"\r\n'
          '#EXT-X-DATERANGE:ID="a",X-TITLE="Cântec https://x"\r\n'
          '#EXTINF:6.0,\r\n'
          'https://hls.radiocrestin.ro/hls/a/seg-1.ts\r\n'
          '#EXTINF:6.0,\r\n'
          'seg-2.ts\r\n';

      final rewritten = HlsHoldProxy.rewritePlaylistUris(
          playlist, (uri) => uri.startsWith('seg') ? null : 'P[$uri]');

      expect(
          rewritten,
          '#EXTM3U\r\n'
          '#EXT-X-MAP:URI="P[/init.mp4]"\r\n'
          '#EXT-X-DATERANGE:ID="a",X-TITLE="Cântec https://x"\r\n'
          '#EXTINF:6.0,\r\n'
          'P[https://hls.radiocrestin.ro/hls/a/seg-1.ts]\r\n'
          '#EXTINF:6.0,\r\n'
          'seg-2.ts\r\n');
    });

    test(
        'absolute and root-relative URIs of an allowed host are sent back '
        'through the proxy; relative ones and other hosts are left alone',
        () async {
      await startProxy();
      final body = '#EXTM3U\n'
          '#EXT-X-DATERANGE:X-TITLE="Bucurie în Domnul"\n'
          '#EXTINF:6.0,\n'
          '${origin.url('/hls/rve/seg-1.ts?t=1')}\n'
          '#EXTINF:6.0,\n'
          '/hls/rve/seg-2.ts\n'
          '#EXTINF:6.0,\n'
          'seg-3.ts\n'
          '#EXTINF:6.0,\n'
          'https://cdn.example.com/seg-4.ts\n';
      origin.handler = (request) async {
        final path = request.uri.path;
        if (path.endsWith('.m3u8')) {
          request.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          request.response.add(utf8.encode(body));
        } else {
          request.response.write('segment $path');
        }
        await request.response.close();
      };
      final session = proxy.beginSession();
      final url = proxy.wrap(origin.url('/hls/rve/index.m3u8'), session)!;

      final got = await get(url);

      final prefix = '/$session/http/127.0.0.1:${origin.port}';
      expect(
          got.body,
          '#EXTM3U\n'
          '#EXT-X-DATERANGE:X-TITLE="Bucurie în Domnul"\n'
          '#EXTINF:6.0,\n'
          '$prefix/hls/rve/seg-1.ts?t=1\n'
          '#EXTINF:6.0,\n'
          '$prefix/hls/rve/seg-2.ts\n'
          '#EXTINF:6.0,\n'
          'seg-3.ts\n'
          '#EXTINF:6.0,\n'
          'https://cdn.example.com/seg-4.ts\n');
      expect(got.headers.contentLength, utf8.encode(got.body).length);
      final segment = await get(Uri.parse(url)
          .resolve('$prefix/hls/rve/seg-2.ts')
          .toString());
      expect(segment.body, 'segment /hls/rve/seg-2.ts');
    });
  });

  group('lifecycle', () {
    test('wraps only http(s) URLs of an allowed host, keeping the query and '
        'the port', () async {
      proxy = HlsHoldProxy(allowedHosts: const ['hls.radiocrestin.ro']);
      expect(proxy.wrap('https://hls.radiocrestin.ro/hls/a/index.m3u8', 1),
          isNull, reason: 'not listening yet');
      await proxy.start();
      final port = proxy.port;

      expect(
          proxy.wrap('https://hls.radiocrestin.ro/hls/a/index.m3u8?ref=x&s=y',
              3),
          'http://127.0.0.1:$port/3/https/hls.radiocrestin.ro/hls/a/'
          'index.m3u8?ref=x&s=y');
      expect(proxy.wrap('https://HLS.radiocrestin.ro:8443/hls/a.m3u8', 4),
          'http://127.0.0.1:$port/4/https/hls.radiocrestin.ro:8443/hls/a.m3u8');
      expect(proxy.wrap('https://stream.example.com/a.mp3', 1), isNull);
      expect(proxy.wrap('ftp://hls.radiocrestin.ro/a.m3u8', 1), isNull);
      expect(proxy.allows('https://hls.radiocrestin.ro/x'), isTrue);
      expect(proxy.allows('https://other.ro/x'), isFalse);
    });

    test('restarts on its previous port, and tells when it could not',
        () async {
      await startProxy();
      final url =
          proxy.wrap(origin.url('/hls/rve/index.m3u8'), proxy.beginSession())!;
      final port = proxy.port!;
      expect(proxy.generation, 1);

      await proxy.stop();
      expect(proxy.isRunning, isFalse);
      expect(proxy.serves(url), isFalse);
      expect(await proxy.start(), isTrue);
      expect(proxy.port, port);
      expect(proxy.generation, 2);
      expect(proxy.serves(url), isTrue);

      await proxy.stop();
      final squatter = await ServerSocket.bind(InternetAddress.loopbackIPv4,
          port);
      addTearDown(squatter.close);
      expect(await proxy.ensureRunning(), isTrue);
      expect(proxy.port, isNot(port));
      expect(proxy.generation, 3);
      expect(proxy.serves(url), isFalse,
          reason: 'what was loaded through the old port must be reloaded');
    });

    test('keeps its port across quick closes and restarts of its socket',
        () async {
      await startProxy();
      final port = proxy.port;
      for (var i = 0; i < 30; i++) {
        // Not awaited: the socket may still be letting go of the port,
        // which dart:io frees only once its close completes.
        unawaited(proxy.debugCloseServer());
        expect(await proxy.ensureRunning(), isTrue);
        await pumpEventQueue();
        expect(await proxy.ensureRunning(), isTrue);
        expect(proxy.port, port, reason: 'round $i');
      }
    });

    test('a session keeps holding across a restart on the same port',
        () async {
      await startProxy();
      final url = await establishedPlaylist();
      await proxy.debugCloseServer();
      expect(await proxy.ensureRunning(), isTrue);
      setOffline(true);

      final held = get(url);
      expect(await stillPending(held), isTrue);
      setOffline(false);
      expect((await held).status, 200);
    });

    test('a listener that throws breaks nothing', () async {
      await startProxy(onEvent: (_) => throw StateError('log failed'));
      final url = await establishedPlaylist();
      setOffline(true);
      final held = get(url);
      expect(await stillPending(held), isTrue);
      setOffline(false);
      expect((await held).status, 200);
    });

    test('prewarm fetches through the upstream client, allowed hosts only',
        () async {
      await startProxy();

      expect(await proxy.prewarm(origin.url('/hls/rve/index.m3u8')), isTrue);
      expect(await proxy.prewarm('https://stream.example.com/a.mp3'), isFalse);
      origin.offline = true;
      expect(await proxy.prewarm(origin.url('/hls/rve/index.m3u8')), isFalse);
      expect(origin.requests.first.uri.path, '/hls/rve/index.m3u8');
    });
  });
}
