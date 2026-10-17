/// A local HTTP proxy that keeps a player's live HLS requests waiting
/// through an internet outage, instead of letting them fail.
///
/// AVPlayer retries a live playlist that fails to load only for a while
/// (macOS 27: ~30 s after its first failure; an iPhone 13 on mobile data,
/// iOS 27: ~100 s), then gives up: it loads nothing more, however long the
/// network has been back, until its buffer runs dry, and then restarts at
/// the live point, skipping what the 2- or 5-minute offset kept. No call
/// the app can make wakes it up. Through this proxy it never sees the
/// outage: a request that fails upstream is held, retried, and answered
/// with the origin's fresh response once the network is back. Measured on
/// the Mac (AVPlayer configured as just_audio configures it): 100, 150 and
/// 280 s outages played through without a stall, the player loading the
/// next segment within ~0.2 s of the network returning.
///
/// A held request is never failed on purpose while its player may still
/// want it: each one closed without a response counts towards the same
/// give-up (measured: three such closes 30 s apart, and AVPlayer silently
/// stopped loading).
///
/// Pure `dart:io`, so that it also runs on its own (the Mac test rig).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The timings and limits of an [HlsHoldProxy].
class HlsHoldProxyTimings {
  const HlsHoldProxyTimings({
    this.retryInterval = const Duration(seconds: 2),
    this.maxHold = const Duration(seconds: 340),
    this.connectTimeout = const Duration(seconds: 5),
    this.responseTimeout = const Duration(seconds: 10),
    this.bodyIdleTimeout = const Duration(seconds: 10),
    this.maxBufferedBytes = 4 * 1024 * 1024,
  });

  /// How often a held request tries the origin again. The internet coming
  /// back (the proxy's `offlineChanges`) or another network
  /// ([HlsHoldProxy.networkChanged]) retries at once.
  final Duration retryInterval;

  /// The longest a request is held: a bit more than the player's forward
  /// buffer (330 s in the app), all an outage can be ridden out with. On
  /// the Mac, AVPlayer itself gave up on a request held for ~300 s.
  final Duration maxHold;

  /// The longest an upstream connection may take to open: DNS, TCP and TLS.
  final Duration connectTimeout;

  /// The longest the origin may take to send its response headers.
  final Duration responseTimeout;

  /// The longest the origin may pause while it sends a body.
  final Duration bodyIdleTimeout;

  /// Bodies up to this size are read whole before the client gets the
  /// response, so that one that fails part way is retried unseen. A larger
  /// one is streamed past this point, and no longer retried.
  final int maxBufferedBytes;
}

/// Why a held request ended. See [HlsHoldProxyEvent.endReason].
enum HlsHoldEnd {
  /// The origin answered: the client got its (fresh) response.
  answered,

  /// A new session began ([HlsHoldProxy.beginSession]): the request's
  /// player has been replaced. Closed without a response.
  released,

  /// The client closed the connection: its player was stopped or gave up.
  clientGone,

  /// Held for [HlsHoldProxyTimings.maxHold]: closed without a response.
  maxHold,

  /// The proxy was stopped ([HlsHoldProxy.stop]).
  stopped,
}

/// What an [HlsHoldProxyEvent] reports.
enum HlsHoldProxyEventKind {
  /// The proxy listens, on [HlsHoldProxyEvent.port].
  serverStarted,

  /// The listening socket closed without [HlsHoldProxy.stop]: an error, or
  /// the system reclaimed it. [HlsHoldProxy.ensureRunning] starts it again.
  serverClosed,

  /// A request failed upstream at the network level and is now held.
  holdStarted,

  /// Another try of a held request failed.
  holdRetryFailed,

  /// A held request ended (see [HlsHoldProxyEvent.endReason]).
  holdEnded,

  /// A request failed upstream at the network level and was failed at once
  /// (closed without a response): its session is not the current one, or
  /// has loaded nothing yet. A new load while offline fails as it would
  /// without the proxy.
  failedFast,

  /// Something unexpected; the request concerned was failed.
  internalError,

  /// A response went to a client ([HlsHoldProxyEvent.status],
  /// [HlsHoldProxyEvent.bytes]). Only with `traceResponses`, for a test
  /// rig's log: one per request.
  responded,
}

/// A notable moment of an [HlsHoldProxy]: never one per normal request
/// (unless asked for, see [HlsHoldProxyEventKind.responded]).
class HlsHoldProxyEvent {
  const HlsHoldProxyEvent(
    this.kind, {
    this.resource,
    this.session,
    this.held,
    this.attempts,
    this.endReason,
    this.status,
    this.bytes,
    this.error,
    this.port,
  });

  final HlsHoldProxyEventKind kind;

  /// The last path segment of the upstream URL: `index-5m.m3u8`, a segment.
  final String? resource;

  /// The session the request belongs to.
  final int? session;

  /// How long the request has been held ([HlsHoldProxyEventKind.holdEnded]).
  final Duration? held;

  /// Upstream tries so far: the failed ones and, once answered, the last.
  final int? attempts;

  /// Why a held request ended ([HlsHoldProxyEventKind.holdEnded]).
  final HlsHoldEnd? endReason;

  /// The status the client got ([HlsHoldEnd.answered], a response).
  final int? status;

  /// The body size the client got, when known (a response).
  final int? bytes;

  /// The failure that started, continued or ended the matter.
  final Object? error;

  /// The listening port (server events).
  final int? port;

  @override
  String toString() {
    final parts = <String>[kind.name];
    if (resource != null) parts.add(resource!);
    if (session != null) parts.add('session=$session');
    if (held != null) {
      parts.add('held=${(held!.inMilliseconds / 1000).toStringAsFixed(1)}s');
    }
    if (attempts != null) parts.add('attempts=$attempts');
    if (endReason != null) parts.add('end=${endReason!.name}');
    if (status != null) parts.add('status=$status');
    if (bytes != null) parts.add('bytes=$bytes');
    if (port != null) parts.add('port=$port');
    if (error != null) parts.add('error=${HlsHoldProxy.describe(error!)}');
    return parts.join(' ');
  }
}

/// A local HTTP proxy for a player's live HLS requests that holds a request
/// through an upstream network failure (see the library documentation).
///
/// [wrap] maps an upstream URL of an allowed host to
/// `http://127.0.0.1:<port>/<session>/<scheme>/<host[:port]><path>?<query>`.
/// The query is kept, and the relative segment URIs of a playlist then
/// resolve through the proxy too; an absolute or root-relative URI of an
/// allowed host in a playlist is rewritten to go through it.
///
/// Every player load is a session ([beginSession]). A request that fails
/// upstream at the network level is held only for the current session,
/// once it is established (something it asked for loaded): a new load
/// while offline fails at once, as it would without the proxy, so the
/// app's retry loop and failover keep working. A held request is tried
/// again every [HlsHoldProxyTimings.retryInterval], and at once when the
/// internet comes back or the network changes ([networkChanged]), until
/// the origin answers, the session is replaced, the client leaves, or
/// [HlsHoldProxyTimings.maxHold] passes. That also holds while the
/// internet is known to work: the origin out of this device's reach (a DNS
/// or routing fault, a network that lies about its internet) is ridden out
/// from the buffer the same way, and should it outlast the buffer, the
/// app's stall handling reloads, as without the proxy. An HTTP status, an
/// error one included, is the origin answering: relayed as is, never held.
///
/// Every response closes its connection: the proxy detaches each client
/// socket from the HTTP server, which tells it when a waiting client
/// leaves and lets a request fail as a network error would (closed without
/// a response). A loopback connection per request costs next to nothing.
class HlsHoldProxy {
  /// [allowedHosts]: the only upstream hosts the proxy fetches from.
  /// [httpClientFactory]: the upstream client (default [HttpClient.new]).
  /// [isOffline] and [offlineChanges]: whether the device is known to be
  /// offline, and its changes, so that a held request tries again the
  /// moment the internet is back; without them it retries on
  /// [HlsHoldProxyTimings.retryInterval] alone. [onEvent]: the notable
  /// moments, for the log; with [traceResponses], every response too (a
  /// test rig's log). [preferredPort]: the port to listen on, when free
  /// (default: any).
  HlsHoldProxy({
    required Iterable<String> allowedHosts,
    HttpClient Function()? httpClientFactory,
    bool Function()? isOffline,
    Stream<bool>? offlineChanges,
    this.timings = const HlsHoldProxyTimings(),
    void Function(HlsHoldProxyEvent event)? onEvent,
    bool traceResponses = false,
    int? preferredPort,
  })  : _allowedHosts = {for (final host in allowedHosts) host.toLowerCase()},
        _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _isOffline = isOffline,
        _offlineChanges = offlineChanges,
        _onEvent = onEvent,
        _traceResponses = traceResponses,
        _lastPort = preferredPort;

  /// The address the proxy listens on.
  static const loopbackHost = '127.0.0.1';

  final HlsHoldProxyTimings timings;
  final Set<String> _allowedHosts;
  final HttpClient Function() _httpClientFactory;
  final bool Function()? _isOffline;
  final Stream<bool>? _offlineChanges;
  final void Function(HlsHoldProxyEvent event)? _onEvent;
  final bool _traceResponses;

  HttpServer? _server;
  // Kept apart: a closed server throws on `port`.
  int? _port;
  int? _lastPort;
  Future<bool>? _starting;
  // The close of a server that stopped listening: its port is only free
  // to bind again once that completes.
  Future<void>? _closingServer;
  int _generation = 0;
  // Bumped by stop(), so that a start in flight does not outlive it.
  int _stops = 0;

  int _session = 0;
  bool _sessionEstablished = false;
  bool _sessionAnswered = false;

  HttpClient? _http;
  int _httpGeneration = 0;
  StreamSubscription<bool>? _offlineSub;
  bool? _lastOffline;
  final Set<_Exchange> _exchanges = {};

  /// Whether the proxy listens.
  bool get isRunning => _server != null;

  /// The port it listens on; null while it does not.
  int? get port => _server == null ? null : _port;

  /// Bumped on every (re)start: compared to its value at a load, it tells
  /// that the proxy was restarted since (possibly on another port).
  int get generation => _generation;

  /// The current session ([beginSession]); 0 before the first.
  int get session => _session;

  /// Whether [url] is one the proxy fetches: http(s), of an allowed host.
  bool allows(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && _allows(uri);
  }

  /// Starts listening on the loopback interface. Restarted, it binds the
  /// port it had before when it can, so that the URLs it handed out keep
  /// working. Never throws: false when it cannot listen.
  Future<bool> start() {
    if (_server != null) return Future.value(true);
    return _starting ??= _bind().whenComplete(() => _starting = null);
  }

  /// Starts the proxy unless it listens and accepts connections. iOS may
  /// reclaim a suspended app's listening socket without a word, so a
  /// running server is checked with a connection to it (well under a
  /// millisecond on the loopback interface).
  Future<bool> ensureRunning() async {
    final server = _server;
    final port = _port;
    if (server != null && port != null) {
      if (await _accepts(port)) return true;
      await _onServerClosed(server, const SocketException('not accepting'));
    }
    return start();
  }

  /// Stops listening, fails every request in flight and closes the
  /// upstream connections. [start] may follow.
  Future<void> stop() async {
    _stops++;
    final server = _server;
    _server = null;
    final sub = _offlineSub;
    _offlineSub = null;
    _lastOffline = null;
    for (final exchange in _exchanges.toList()) {
      exchange.cancel(HlsHoldEnd.stopped);
    }
    _http?.close(force: true);
    _http = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    if (server != null) await (_closingServer = _closeQuietly(server));
  }

  /// Closes the listening socket as iOS reclaiming it would, for tests and
  /// the Mac rig. Requests in flight carry on: their sockets are detached.
  Future<void> debugCloseServer() async {
    final server = _server;
    if (server != null) await (_closingServer = _closeQuietly(server));
  }

  /// Starts a session, for a new player load, and returns it. The requests
  /// still held for an older session are closed without a response.
  int beginSession() {
    final session = ++_session;
    _sessionEstablished = false;
    _sessionAnswered = false;
    for (final exchange in _exchanges.toList()) {
      if (exchange.held && exchange.target.session != session) {
        exchange.cancel(HlsHoldEnd.released);
      }
    }
    return session;
  }

  /// Whether the origin answered a request of [session], the current one,
  /// with any status: the way through the proxy works. A load through the
  /// proxy that failed without that may have failed for the proxy's own
  /// sake (an upstream path only the system's network stack has, such as
  /// a network that requires an HTTP proxy).
  bool originAnswered(int session) => session == _session && _sessionAnswered;

  /// The proxy's URL for [upstreamUrl] in [session]; null when the proxy
  /// does not listen or [upstreamUrl] is not one it fetches (see [allows]).
  String? wrap(String upstreamUrl, int session) {
    final port = this.port;
    final uri = Uri.tryParse(upstreamUrl);
    if (port == null || uri == null || !_allows(uri)) return null;
    return 'http://$loopbackHost:$port${_proxyPath(uri, session)}';
  }

  /// Whether [proxyUrl], from [wrap], still reaches the proxy: it listens
  /// on that URL's port.
  bool serves(String proxyUrl) {
    final port = this.port;
    final uri = Uri.tryParse(proxyUrl);
    return port != null &&
        uri != null &&
        uri.host == loopbackHost &&
        uri.port == port;
  }

  /// Drops the pooled upstream connections, so that the next requests open
  /// new ones: one opened on a network just left would hang. Requests in
  /// flight finish on theirs.
  void renewConnections() {
    final http = _http;
    _http = null;
    http?.close();
  }

  /// The device moved to another network (WiFi and mobile data): the
  /// requests in flight on the one it left would hang until their timeouts.
  /// They are cut, so that each tries again at once on a new connection, as
  /// CFNetwork does: a request not held yet through its immediate retry, a
  /// held one through a retry now.
  void networkChanged() {
    for (final exchange in _exchanges.toList()) {
      if (exchange.held) exchange.retryNow();
    }
    final http = _http;
    _http = null;
    http?.close(force: true);
  }

  /// Opens an upstream connection ahead of a load (DNS, TCP and TLS) with
  /// a GET of [upstreamUrl] whose body is thrown away: the player's first
  /// request then reuses it. Never throws: whether the origin answered.
  Future<bool> prewarm(
    String upstreamUrl, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final uri = Uri.tryParse(upstreamUrl);
    if (uri == null || !_allows(uri)) return false;
    var abandoned = false;
    try {
      final opening = _client().$1.getUrl(uri);
      opening.then((request) {
        request.done.ignore();
        if (abandoned) request.abort();
      }, onError: (Object _) {}).ignore();
      final request = await opening.timeout(timeout);
      final response = await request.close().timeout(timeout, onTimeout: () {
        request.abort();
        throw TimeoutException('no response headers');
      });
      await response.drain<void>().timeout(timeout);
      return true;
    } catch (_) {
      abandoned = true;
      return false;
    }
  }

  /// A short description of a request failure, for the log.
  static String describe(Object error) {
    if (error is SocketException) {
      final os = error.osError;
      return 'SocketException: ${error.message}'
          '${os == null ? '' : ' (${os.errorCode} ${os.message})'}';
    }
    if (error is TimeoutException) return 'TimeoutException';
    final text = error.toString();
    return text.length > 160 ? text.substring(0, 160) : text;
  }

  /// Rewrites the URIs of an HLS [playlist] with [map]: the URI lines and
  /// the `URI="…"` attributes of the tags. [map] returns null to keep one.
  /// Everything else, line endings included, stays as it is.
  static String rewritePlaylistUris(
    String playlist,
    String? Function(String uri) map,
  ) {
    final lines = playlist.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final crlf = line.endsWith('\r');
      final content = crlf ? line.substring(0, line.length - 1) : line;
      String? rewritten;
      if (content.startsWith('#')) {
        if (content.contains('URI="')) {
          rewritten = content.replaceAllMapped(_uriAttribute, (m) {
            final mapped = map(m[1]!);
            return mapped == null ? m[0]! : 'URI="$mapped"';
          });
        }
      } else {
        final uri = content.trim();
        final mapped = uri.isEmpty ? null : map(uri);
        if (mapped != null) rewritten = content.replaceFirst(uri, mapped);
      }
      if (rewritten != null && rewritten != content) {
        lines[i] = crlf ? '$rewritten\r' : rewritten;
      }
    }
    return lines.join('\n');
  }

  static final _uriAttribute = RegExp(r'URI="([^"]*)"');

  /// Whether a try failed for want of a network (no route, reset, TLS,
  /// timeout), which a hold may ride out; anything else is a fault.
  static bool _isNetworkFailure(Object error) =>
      error is IOException || error is TimeoutException;

  // ── Server ──────────────────────────────────────────────────────────

  Future<bool> _bind() async {
    final stops = _stops;
    final server = await _bindPreferredPort() ?? await _bindLoopback(0);
    if (server == null) return false;
    if (stops != _stops) {
      // Stopped while it bound.
      await _closeQuietly(server);
      return false;
    }
    server
      ..autoCompress = false
      ..serverHeader = null;
    final port = server.port;
    _server = server;
    _port = port;
    _lastPort = port;
    _generation++;
    _listenToOfflineChanges();
    server.listen(
      _onRequest,
      onError: (Object e) => unawaited(_onServerClosed(server, e)),
      onDone: () => unawaited(_onServerClosed(server, null)),
      cancelOnError: true,
    );
    _emit(HlsHoldProxyEvent(HlsHoldProxyEventKind.serverStarted, port: port));
    return true;
  }

  /// A server on the port the proxy had before, so that the URLs it handed
  /// out keep working; null when there was none, or it is taken.
  Future<HttpServer?> _bindPreferredPort() async {
    final port = _lastPort;
    if (port == null) return null;
    // dart:io frees the port of a closed server only once its close
    // completes: bound before, it fails as taken (measured: 3 times in 300).
    final closing = _closingServer;
    if (closing != null) await closing;
    final server = await _bindLoopback(port);
    if (server != null) return server;
    // Another try in case the socket is still being let go.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return _bindLoopback(port);
  }

  /// A server on [port] of the loopback interface (0: any free one); null
  /// when that port is taken, or nothing can listen (then reported).
  Future<HttpServer?> _bindLoopback(int port) async {
    try {
      return await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } catch (e) {
      if (port == 0) {
        _emit(HlsHoldProxyEvent(HlsHoldProxyEventKind.internalError,
            error: e));
      }
      return null;
    }
  }

  /// [server] stopped listening: an error, the system reclaiming it, or
  /// [ensureRunning] finding it deaf. Completes once it is closed.
  Future<void> _onServerClosed(HttpServer server, Object? error) {
    if (identical(_server, server)) {
      _server = null;
      _closingServer = _closeQuietly(server);
      _emit(HlsHoldProxyEvent(HlsHoldProxyEventKind.serverClosed,
          port: _port, error: error));
    }
    return _closingServer ?? Future<void>.value();
  }

  static Future<void> _closeQuietly(HttpServer server) async {
    try {
      await server.close(force: true);
    } catch (_) {}
  }

  static Future<bool> _accepts(int port) async {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(seconds: 1));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _listenToOfflineChanges() {
    final changes = _offlineChanges;
    if (changes == null || _offlineSub != null) return;
    _lastOffline = _offlineNow();
    try {
      _offlineSub = changes.listen(_onOfflineChanged, onError: (Object _) {});
    } catch (e) {
      // A single-subscription stream listened to before: no retry at once
      // when the internet is back, the interval still retries.
      _emit(HlsHoldProxyEvent(HlsHoldProxyEventKind.internalError, error: e));
    }
  }

  /// The internet came back: the held requests try again at once, on new
  /// connections (the pooled ones may belong to the network that left).
  void _onOfflineChanged(bool offline) {
    final wasOffline = _lastOffline;
    _lastOffline = offline;
    if (offline || wasOffline != true) return;
    renewConnections();
    for (final exchange in _exchanges.toList()) {
      if (exchange.held) exchange.retryNow();
    }
  }

  bool? _offlineNow() {
    final isOffline = _isOffline;
    if (isOffline == null) return null;
    try {
      return isOffline();
    } catch (_) {
      return null;
    }
  }

  // ── Requests ────────────────────────────────────────────────────────

  void _onRequest(HttpRequest request) {
    _handle(request).catchError((Object e) {
      _emit(HlsHoldProxyEvent(HlsHoldProxyEventKind.internalError, error: e));
    });
  }

  Future<void> _handle(HttpRequest request) async {
    _Client? client;
    try {
      final target = _parseTarget(request.uri);
      final method = request.method;
      final headers = _forwardedHeaders(request.headers);
      client =
          _Client(await request.response.detachSocket(writeHeaders: false));
      if (target == null) {
        await client.respondEmpty(404);
        return;
      }
      if (method != 'GET' && method != 'HEAD') {
        await client.respondEmpty(405);
        return;
      }
      final exchange = _Exchange(this, client, target, method, headers);
      _exchanges.add(exchange);
      try {
        await exchange.run();
      } finally {
        _exchanges.remove(exchange);
      }
    } catch (e) {
      // A client that left before its response is no fault.
      if (e is! IOException) {
        _emit(
            HlsHoldProxyEvent(HlsHoldProxyEventKind.internalError, error: e));
      }
      client?.abort();
    }
  }

  _Target? _parseTarget(Uri requestUri) {
    // '/<session>/<scheme>/<authority>/<path…>'
    final parts = requestUri.path.split('/');
    if (parts.length < 5 || parts[0].isNotEmpty) return null;
    final session = int.tryParse(parts[1]);
    final scheme = parts[2];
    if (session == null || (scheme != 'http' && scheme != 'https')) {
      return null;
    }
    final query = requestUri.hasQuery ? '?${requestUri.query}' : '';
    final upstream = Uri.tryParse(
        '$scheme://${parts[3]}/${parts.sublist(4).join('/')}$query');
    if (upstream == null || !_allows(upstream)) return null;
    return _Target(session, upstream);
  }

  bool _allows(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.userInfo.isEmpty &&
      _allowedHosts.contains(uri.host.toLowerCase());

  /// `/<session>/<scheme>/<host[:port]><path>?<query>`: root-relative, so
  /// that it resolves against whichever proxy URL the player used.
  static String _proxyPath(Uri uri, int session) {
    final authority = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    final path = uri.path.isEmpty ? '/' : uri.path;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    return '/$session/${uri.scheme}/$authority$path$query';
  }

  /// The request headers that go upstream. Accept-Encoding is the proxy's
  /// own (see [_Attempt]); hop-by-hop ones stay on the loopback leg.
  static const _forwardedRequestHeaders = [
    'user-agent',
    'accept',
    'accept-language',
    'range',
    'if-range',
    'if-none-match',
    'if-modified-since',
    'if-match',
    'if-unmodified-since',
    'x-playback-session-id',
    'cache-control',
    'pragma',
  ];

  static List<(String, List<String>)> _forwardedHeaders(HttpHeaders headers) =>
      [
        for (final name in _forwardedRequestHeaders)
          if (headers[name] case final values? when values.isNotEmpty)
            (name, values),
      ];

  (HttpClient, int) _client() {
    var http = _http;
    if (http == null) {
      http = _http = _httpClientFactory()
        ..connectionTimeout = timings.connectTimeout
        ..autoUncompress = true;
      _httpGeneration++;
    }
    return (http, _httpGeneration);
  }

  /// After a failure on the client of [generation], the next try opens a
  /// new connection: a pooled one may be dead (network change), and the
  /// pool may hold more of them.
  void _renewAfterFailure(int generation) {
    if (generation == _httpGeneration) renewConnections();
  }

  bool _mayHold(int session) => session == _session && _sessionEstablished;

  void _established(int session) {
    if (session == _session) _sessionEstablished = true;
  }

  void _answered(int session) {
    if (session == _session) _sessionAnswered = true;
  }

  /// [body] with the URIs that would not come back through the proxy
  /// rewritten (see [_proxiedUri]); [body] itself when there are none.
  Uint8List _rewritePlaylist(Uint8List body, _Target target) {
    // Latin-1 maps every byte to one character and back, so the bytes not
    // rewritten (UTF-8 song titles included) stay exactly as they were.
    final text = latin1.decode(body);
    if (!text.contains('://') &&
        !text.contains('\n/') &&
        !text.contains('URI="/')) {
      return body;
    }
    final rewritten =
        rewritePlaylistUris(text, (uri) => _proxiedUri(uri, target));
    return rewritten == text ? body : latin1.encode(rewritten);
  }

  /// The proxy path for a URI of [target]'s response that would not
  /// resolve through the proxy by itself: absolute on an allowed host, or
  /// root-relative. A scheme-relative URI of another host gets its scheme,
  /// which resolving it against the proxy's `http` would get wrong. Null:
  /// keep it (relative, or another host).
  String? _proxiedUri(String uri, _Target target) {
    final upstream = target.upstream;
    if (uri.startsWith('//')) {
      final absolute = Uri.tryParse('${upstream.scheme}:$uri');
      if (absolute == null) return null;
      return _allows(absolute)
          ? _proxyPath(absolute, target.session)
          : absolute.toString();
    }
    if (uri.startsWith('/')) {
      final authority = upstream.hasPort
          ? '${upstream.host}:${upstream.port}'
          : upstream.host;
      return '/${target.session}/${upstream.scheme}/$authority$uri';
    }
    final parsed = Uri.tryParse(uri);
    if (parsed == null || !parsed.hasScheme || !_allows(parsed)) return null;
    return _proxyPath(parsed, target.session);
  }

  void _emit(HlsHoldProxyEvent event) {
    final onEvent = _onEvent;
    if (onEvent == null) return;
    try {
      onEvent(event);
    } catch (_) {
      // The log's trouble is not the request's.
    }
  }
}

/// The upstream URL of a request, and its session.
class _Target {
  const _Target(this.session, this.upstream);

  final int session;
  final Uri upstream;

  /// The last path segment, for the log.
  String get resource {
    final segments = upstream.pathSegments;
    return segments.isEmpty || segments.last.isEmpty ? '/' : segments.last;
  }
}

/// The result of one upstream try.
sealed class _Result {
  const _Result();
}

/// The origin's response: whole ([body]), or, past the buffer limit, its
/// start ([body]) and the rest still to read ([rest]).
class _Response extends _Result {
  const _Response(this.status, this.reason, this.headers, this.body,
      {this.rest, this.length});

  final int status;
  final String reason;

  /// The headers for the client; Content-Length included for a whole body.
  final List<(String, String)> headers;
  final Uint8List body;

  /// The rest of a body over the buffer limit, still to read.
  final StreamIterator<List<int>>? rest;

  /// The length of a body over the limit when known (not decompressed).
  final int? length;
}

/// No response arrived (whole), for [error]; nothing reached the client.
class _Failure extends _Result {
  const _Failure(this.error, this.httpGeneration, {this.forRetry = false});

  final Object error;

  /// The upstream client the try used (see [HlsHoldProxy._renewAfterFailure]).
  final int httpGeneration;

  /// Aborted to try again at once (the internet came back), not failed.
  final bool forRetry;
}

/// One client request, from its arrival to its response or failure.
class _Exchange {
  _Exchange(this.proxy, this.client, this.target, this.method, this.headers) {
    unawaited(client.gone.then((_) => cancel(HlsHoldEnd.clientGone)));
  }

  final HlsHoldProxy proxy;
  final _Client client;
  final _Target target;
  final String method;
  final List<(String, List<String>)> headers;

  /// Whether the request is held (see [HlsHoldProxy]).
  bool held = false;

  HlsHoldEnd? _cancelled;
  _Attempt? _attempt;
  Completer<void>? _wake;
  bool _retryNow = false;

  HlsHoldProxyTimings get _timings => proxy.timings;

  /// Ends the request for [reason]; a try in flight is aborted.
  void cancel(HlsHoldEnd reason) {
    _cancelled ??= reason;
    _attempt?.abort();
    _wakeUp();
  }

  /// Tries again at once: the internet came back. A try in flight is
  /// aborted, its connection perhaps on the network that left.
  void retryNow() {
    _retryNow = true;
    _attempt?.abort(forRetry: true);
    _wakeUp();
  }

  void _wakeUp() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> run() async {
    var result = await _try();
    if (result is _Failure && _cancelled == null) {
      // A pooled connection that died with a network change fails at
      // once: try again at once, on a new one, as CFNetwork does.
      proxy._renewAfterFailure(result.httpGeneration);
      result = await _try();
    }
    if (_cancelled != null) {
      _discard(result);
      client.abort();
      return;
    }
    switch (result) {
      case _Response():
        await _answer(result);
      case _Failure(:final error):
        if (!HlsHoldProxy._isNetworkFailure(error)) {
          _report(HlsHoldProxyEventKind.internalError, error);
          client.abort();
        } else if (!proxy._mayHold(target.session)) {
          _report(HlsHoldProxyEventKind.failedFast, error);
          client.abort();
        } else {
          await _hold(error);
        }
    }
  }

  void _report(HlsHoldProxyEventKind kind, Object error) =>
      proxy._emit(HlsHoldProxyEvent(kind,
          resource: target.resource, session: target.session, error: error));

  /// Holds the request that failed with [firstError] until it ends (see
  /// [HlsHoldProxy]).
  Future<void> _hold(Object firstError) async {
    held = true;
    final watch = Stopwatch()..start();
    // The first try and its retry at once.
    var attempts = 2;
    var lastError = firstError;
    _report(HlsHoldProxyEventKind.holdStarted, firstError);
    while (true) {
      final end = await _waitForRetry(watch);
      if (end != null) return _endHold(end, watch, attempts, lastError);
      final result = await _try();
      final cancelled = _cancelled;
      if (cancelled != null) {
        _discard(result);
        return _endHold(cancelled, watch, attempts, lastError);
      }
      switch (result) {
        case _Response():
          proxy._emit(HlsHoldProxyEvent(HlsHoldProxyEventKind.holdEnded,
              resource: target.resource,
              session: target.session,
              held: watch.elapsed,
              attempts: attempts + 1,
              endReason: HlsHoldEnd.answered,
              status: result.status));
          return _answer(result);
        case _Failure(:final error, :final forRetry):
          if (forRetry) continue;
          attempts++;
          lastError = error;
          proxy._emit(HlsHoldProxyEvent(HlsHoldProxyEventKind.holdRetryFailed,
              resource: target.resource,
              session: target.session,
              attempts: attempts,
              error: error));
      }
    }
  }

  /// Waits for the next try: null to try, or why the hold ends.
  Future<HlsHoldEnd?> _waitForRetry(Stopwatch watch) async {
    if (_cancelled != null) return _cancelled;
    final left = _timings.maxHold - watch.elapsed;
    if (left <= Duration.zero) return HlsHoldEnd.maxHold;
    if (_retryNow) {
      _retryNow = false;
      return null;
    }
    final wake = _wake = Completer<void>();
    final interval = _timings.retryInterval;
    final timer = Timer(left < interval ? left : interval, () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
    timer.cancel();
    _wake = null;
    _retryNow = false;
    if (_cancelled != null) return _cancelled;
    if (watch.elapsed >= _timings.maxHold) return HlsHoldEnd.maxHold;
    return null;
  }

  void _endHold(
      HlsHoldEnd reason, Stopwatch watch, int attempts, Object error) {
    proxy._emit(HlsHoldProxyEvent(HlsHoldProxyEventKind.holdEnded,
        resource: target.resource,
        session: target.session,
        held: watch.elapsed,
        attempts: attempts,
        endReason: reason,
        error: error));
    client.abort();
  }

  Future<_Result> _try() async {
    final attempt = _attempt = _Attempt(this);
    try {
      return await attempt.run();
    } finally {
      if (identical(_attempt, attempt)) _attempt = null;
    }
  }

  /// Lets go of a response no one will get.
  static void _discard(_Result result) {
    if (result is _Response) result.rest?.cancel().ignore();
  }

  Future<void> _answer(_Response response) async {
    if (response.status >= 200 && response.status < 300) {
      proxy._established(target.session);
    }
    final rest = response.rest;
    if (rest == null) {
      await client.respond(
          response.status, response.reason, response.headers, response.body);
    } else {
      await client.respondStreaming(response, rest);
    }
    if (proxy._traceResponses) {
      proxy._emit(HlsHoldProxyEvent(HlsHoldProxyEventKind.responded,
          resource: target.resource,
          session: target.session,
          status: response.status,
          bytes: rest == null ? response.body.length : response.length));
    }
  }
}

/// One upstream request of an [_Exchange].
class _Attempt {
  _Attempt(this.exchange);

  final _Exchange exchange;
  final Completer<_Failure> _aborted = Completer<_Failure>();
  HttpClientRequest? _request;
  int _httpGeneration = 0;

  HlsHoldProxy get _proxy => exchange.proxy;
  HlsHoldProxyTimings get _timings => exchange.proxy.timings;

  /// Ends this try at once, as failed ([forRetry]: to try again at once).
  void abort({bool forRetry = false}) {
    if (_aborted.isCompleted) return;
    _aborted.complete(
        _Failure(const _Aborted(), _httpGeneration, forRetry: forRetry));
    _request?.abort(const _Aborted());
  }

  Future<_Result> run() {
    final running = _run();
    // A response that arrives after an abort is no one's.
    running.then((result) {
      if (_aborted.isCompleted) _Exchange._discard(result);
    }).ignore();
    return Future.any([running, _aborted.future]);
  }

  Future<_Result> _run() async {
    final (http, generation) = _proxy._client();
    _httpGeneration = generation;
    var abandoned = false;
    try {
      final opening = http.openUrl(exchange.method, exchange.target.upstream);
      // A connection that opens after a timeout or an abort is closed, and
      // its outcome handled.
      opening.then((request) {
        request.done.ignore();
        if (abandoned || _aborted.isCompleted) {
          request.abort(const _Aborted());
        }
      }, onError: (Object _) {}).ignore();
      final HttpClientRequest request;
      try {
        request = await opening.timeout(_timings.connectTimeout);
      } catch (_) {
        abandoned = true;
        rethrow;
      }
      if (_aborted.isCompleted) return await _aborted.future;
      _request = request;
      request
        ..followRedirects = false
        ..persistentConnection = true;
      _copyHeaders(request.headers);
      final response = await request.close().timeout(
        _timings.responseTimeout,
        onTimeout: () {
          request.abort(const _Aborted());
          throw TimeoutException('no response headers');
        },
      );
      _proxy._answered(exchange.target.session);
      return await _read(response);
    } catch (e) {
      return _Failure(e, generation);
    }
  }

  void _copyHeaders(HttpHeaders headers) {
    for (final (name, values) in exchange.headers) {
      headers.set(name, values);
    }
    // A range, or the length a HEAD reports, is about the bytes as stored:
    // no compression then. Otherwise compressed upstream (playlists shrink
    // to a quarter) and decompressed here: the loopback leg costs nothing.
    final identity =
        exchange.method == 'HEAD' || headers['range'] != null;
    headers.set(
        HttpHeaders.acceptEncodingHeader, identity ? 'identity' : 'gzip');
  }

  Future<_Result> _read(HttpClientResponse response) async {
    final status = response.statusCode;
    final decompressed = response.compressionState ==
        HttpClientResponseCompressionState.decompressed;
    final iterator =
        StreamIterator<List<int>>(response.timeout(_timings.bodyIdleTimeout));
    final body = BytesBuilder();
    var handedOver = false;
    try {
      while (await iterator.moveNext()) {
        body.add(iterator.current);
        if (body.length > _timings.maxBufferedBytes) {
          handedOver = true;
          final upstreamLength = response.headers.contentLength;
          return _Response(
            status,
            response.reasonPhrase,
            _responseHeaders(response, decompressed: decompressed),
            body.takeBytes(),
            rest: iterator,
            length: decompressed || upstreamLength < 0 ? null : upstreamLength,
          );
        }
      }
    } finally {
      if (!handedOver) await iterator.cancel();
    }
    var bytes = body.takeBytes();
    if (status >= 200 && status < 300 && _isPlaylist(response)) {
      bytes = _proxy._rewritePlaylist(bytes, exchange.target);
    }
    final headers = _responseHeaders(response, decompressed: decompressed);
    final length = _contentLength(response, status, bytes, decompressed);
    if (length != null) headers.add(('Content-Length', '$length'));
    return _Response(status, response.reasonPhrase, headers, bytes);
  }

  /// The length the client is told; null for none (no body allowed).
  int? _contentLength(HttpClientResponse response, int status,
      Uint8List body, bool decompressed) {
    if (status < 200 || status == 204 || status == 304) return null;
    if (exchange.method != 'HEAD') return body.length;
    final upstream = response.headers.contentLength;
    return decompressed || upstream < 0 ? null : upstream;
  }

  bool _isPlaylist(HttpClientResponse response) {
    // The list, not `contentType` or `value`, which throw on a repeated
    // header: a malformed answer must not read as a network failure.
    final type =
        response.headers[HttpHeaders.contentTypeHeader]?.first.toLowerCase() ??
            '';
    final path = exchange.target.upstream.path.toLowerCase();
    return type.contains('mpegurl') ||
        path.endsWith('.m3u8') ||
        path.endsWith('.m3u');
  }

  /// The response headers for the client, Content-Length aside.
  List<(String, String)> _responseHeaders(
    HttpClientResponse response, {
    required bool decompressed,
  }) {
    final headers = <(String, String)>[];
    void relay(String name) {
      for (final value in response.headers[name] ?? const <String>[]) {
        headers.add((name, value));
      }
    }

    _relayedResponseHeaders.forEach(relay);
    // Decompressed here, the body is no longer encoded.
    if (!decompressed) relay(HttpHeaders.contentEncodingHeader);
    final location = response.headers[HttpHeaders.locationHeader]?.first;
    if (location != null) {
      headers.add((
        HttpHeaders.locationHeader,
        _proxy._proxiedUri(location, exchange.target) ?? location,
      ));
    }
    return headers;
  }

  static const _relayedResponseHeaders = [
    'content-type',
    'content-range',
    'accept-ranges',
    'cache-control',
    'expires',
    'last-modified',
    'etag',
    'date',
    'age',
  ];
}

/// Why an [_Attempt] ended early.
class _Aborted implements Exception {
  const _Aborted();

  @override
  String toString() => 'aborted';
}

/// A client connection, detached from the HTTP server: the proxy writes
/// its one response itself, and learns when the client leaves.
class _Client {
  _Client(this._socket) {
    _socket.done.ignore();
    _socket.listen(
      (_) {},
      onError: (Object _) => _markGone(),
      onDone: _markGone,
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final Completer<void> _gone = Completer<void>();
  bool _finished = false;

  /// Completes when the client closes the connection.
  Future<void> get gone => _gone.future;

  void _markGone() {
    if (!_gone.isCompleted) _gone.complete();
  }

  /// Closes the connection without a response: the client sees a network
  /// error, as it would without the proxy.
  void abort() {
    if (_finished) return;
    _finished = true;
    _socket.destroy();
  }

  Future<void> respondEmpty(int status) =>
      respond(status, '', const [('Content-Length', '0')], Uint8List(0));

  /// Sends a whole response, then closes the connection.
  Future<void> respond(int status, String reason,
      List<(String, String)> headers, List<int> body) async {
    if (_finished) return;
    _finished = true;
    try {
      _socket.add(_head(status, reason, headers));
      if (body.isNotEmpty) _socket.add(body);
      await _socket.flush();
    } catch (_) {
      _socket.destroy();
      return;
    }
    _close();
  }

  /// Sends a response whose body is over the buffer limit: its start, then
  /// the rest as it arrives. A failure part way cuts the connection.
  Future<void> respondStreaming(
      _Response response, StreamIterator<List<int>> rest) async {
    if (_finished) {
      await rest.cancel();
      return;
    }
    _finished = true;
    final length = response.length;
    final chunked = length == null;
    final headers = [
      ...response.headers,
      if (chunked)
        ('Transfer-Encoding', 'chunked')
      else
        ('Content-Length', '$length'),
    ];
    try {
      _socket.add(_head(response.status, response.reason, headers));
      _write(response.body, chunked);
      var unflushed = response.body.length;
      while (await rest.moveNext()) {
        final chunk = rest.current;
        _write(chunk, chunked);
        unflushed += chunk.length;
        if (unflushed >= 256 * 1024) {
          await _socket.flush();
          unflushed = 0;
        }
      }
      if (chunked) _socket.add(_lastChunk);
      await _socket.flush();
    } catch (_) {
      await rest.cancel();
      _socket.destroy();
      return;
    }
    _close();
  }

  void _write(List<int> bytes, bool chunked) {
    if (bytes.isEmpty) return;
    if (!chunked) {
      _socket.add(bytes);
      return;
    }
    _socket
      ..add(ascii.encode('${bytes.length.toRadixString(16)}\r\n'))
      ..add(bytes)
      ..add(_crlf);
  }

  static final _crlf = ascii.encode('\r\n');
  static final _lastChunk = ascii.encode('0\r\n\r\n');

  /// Closes once the client has read the response; a client that does not
  /// close its side in time is cut.
  void _close() {
    _socket
        .close()
        .timeout(const Duration(seconds: 5))
        .catchError((Object _) => _socket.destroy())
        .ignore();
  }

  static List<int> _head(
      int status, String reason, List<(String, String)> headers) {
    final head = StringBuffer('HTTP/1.1 $status ')
      ..write(reason.isEmpty ? _reasons[status] ?? 'Status' : reason)
      ..write('\r\n');
    for (final (name, value) in headers) {
      head
        ..write(name)
        ..write(': ')
        ..write(value)
        ..write('\r\n');
    }
    head.write('Connection: close\r\n\r\n');
    // Header values came from an HTTP parser: a byte per character.
    return latin1.encode(head.toString());
  }

  static const _reasons = {
    200: 'OK',
    206: 'Partial Content',
    404: 'Not Found',
    405: 'Method Not Allowed',
  };
}
