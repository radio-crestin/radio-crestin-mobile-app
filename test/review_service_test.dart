import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/review_service.dart';

/// Local HTTP server that records every incoming request and replies
/// with caller-controlled status codes / bodies. Tests inject the
/// expected response, then assert on what ReviewService sent.
class _FakeReviewsServer {
  late HttpServer _server;
  final List<_RecordedRequest> requests = [];
  int statusCode = 200;
  String body = '{}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final raw = await utf8.decodeStream(req);
      requests.add(_RecordedRequest(
        method: req.method,
        path: req.uri.path,
        body: raw,
      ));
      req.response.statusCode = statusCode;
      req.response.headers.contentType = ContentType.json;
      req.response.write(body);
      await req.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);

  String get baseUrl => 'http://${_server.address.host}:${_server.port}';
}

class _RecordedRequest {
  _RecordedRequest({
    required this.method,
    required this.path,
    required this.body,
  });
  final String method;
  final String path;
  final String body;
}

void main() {
  // ReviewService captures CONSTANTS.REVIEWS_URL into a `static final` at
  // first reference, so we have to point it at the fake server BEFORE
  // touching the service. We do that in setUpAll using HttpOverrides
  // instead — that lets us intercept the real radiocrestin URL.

  late _FakeReviewsServer server;
  late HttpOverrides? oldOverrides;

  setUp(() async {
    server = _FakeReviewsServer();
    await server.start();
    oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _RedirectOverrides(server.baseUrl);
  });

  tearDown(() async {
    HttpOverrides.global = oldOverrides;
    await server.stop();
  });

  group('ReviewService.submitReview', () {
    test('returns success on 200 with non-OperationInfo data', () async {
      server.body = jsonEncode({
        'data': {
          'submit_review': {'__typename': 'Review', 'id': 1},
        },
      });

      final result = await ReviewService.submitReview(
        stationId: 1,
        stars: 5,
        message: 'Excelent',
        userIdentifier: 'user-123',
      );

      expect(result.success, true);
      expect(result.error, isNull);
      expect(server.requests, hasLength(1));
      final req = server.requests.first;
      expect(req.method, 'POST');
      final sent = jsonDecode(req.body) as Map<String, dynamic>;
      expect(sent['station_id'], 1);
      expect(sent['stars'], 5);
      expect(sent['message'], 'Excelent');
      expect(sent['user_identifier'], 'user-123');
      expect(sent.containsKey('song_id'), false);
    });

    test('includes song_id when songId > 0', () async {
      server.body = jsonEncode({
        'data': {'submit_review': {'__typename': 'Review'}},
      });

      await ReviewService.submitReview(
        stationId: 2,
        stars: 4,
        message: 'm',
        userIdentifier: 'u',
        songId: 7,
      );

      final sent = jsonDecode(server.requests.first.body)
          as Map<String, dynamic>;
      expect(sent['song_id'], 7);
    });

    test('omits song_id when songId is null or zero', () async {
      server.body = jsonEncode({
        'data': {'submit_review': {'__typename': 'Review'}},
      });

      await ReviewService.submitReview(
        stationId: 2,
        stars: 4,
        message: 'm',
        userIdentifier: 'u',
        songId: 0,
      );

      final sent = jsonDecode(server.requests.first.body)
          as Map<String, dynamic>;
      expect(sent.containsKey('song_id'), false);
    });

    test('returns network error for non-200 status', () async {
      server.statusCode = 500;
      final result = await ReviewService.submitReview(
        stationId: 1,
        stars: 5,
        message: 'm',
        userIdentifier: 'u',
      );
      expect(result.success, false);
      expect(result.error, contains('500'));
    });

    test('returns generic error when data.submit_review is missing',
        () async {
      server.body = jsonEncode({'data': {}});
      final result = await ReviewService.submitReview(
        stationId: 1,
        stars: 5,
        message: 'm',
        userIdentifier: 'u',
      );
      expect(result.success, false);
      expect(result.error, contains('A apărut o eroare'));
    });

    test('extracts message from OperationInfo response', () async {
      server.body = jsonEncode({
        'data': {
          'submit_review': {
            '__typename': 'OperationInfo',
            'messages': [
              {'message': 'Recenzie deja trimisă'},
            ],
          },
        },
      });
      final result = await ReviewService.submitReview(
        stationId: 1,
        stars: 5,
        message: 'm',
        userIdentifier: 'u',
      );
      expect(result.success, false);
      expect(result.error, 'Recenzie deja trimisă');
    });

    test('falls back to generic message for empty OperationInfo messages',
        () async {
      server.body = jsonEncode({
        'data': {
          'submit_review': {
            '__typename': 'OperationInfo',
            'messages': [],
          },
        },
      });
      final result = await ReviewService.submitReview(
        stationId: 1,
        stars: 5,
        message: 'm',
        userIdentifier: 'u',
      );
      expect(result.success, false);
      expect(result.error, contains('A apărut o eroare'));
    });

    test('catches exceptions and returns user-friendly error', () async {
      // Stop the server mid-test to force a SocketException.
      await server.stop();
      final result = await ReviewService.submitReview(
        stationId: 1,
        stars: 5,
        message: 'm',
        userIdentifier: 'u',
      );
      expect(result.success, false);
      expect(result.error, contains('încercați din nou'));
    });
  });

  group('ReviewService.deleteReview', () {
    test('returns success on 200 with non-OperationInfo response', () async {
      server.body = jsonEncode({
        'data': {'delete_review': {'__typename': 'OK'}},
      });
      final result = await ReviewService.deleteReview(stationId: 1);
      expect(result.success, true);
      expect(result.error, isNull);
      // POST goes to /reviews/delete/
      expect(server.requests.first.path, contains('delete'));
      final sent = jsonDecode(server.requests.first.body)
          as Map<String, dynamic>;
      expect(sent['station_id'], 1);
      expect(sent.containsKey('song_id'), false);
    });

    test('includes song_id when provided', () async {
      server.body = jsonEncode({
        'data': {'delete_review': {'__typename': 'OK'}},
      });
      await ReviewService.deleteReview(stationId: 1, songId: 7);
      final sent = jsonDecode(server.requests.first.body)
          as Map<String, dynamic>;
      expect(sent['song_id'], 7);
    });

    test('returns network error for non-200', () async {
      server.statusCode = 503;
      final result = await ReviewService.deleteReview(stationId: 1);
      expect(result.success, false);
      expect(result.error, contains('503'));
    });

    test('extracts message from OperationInfo', () async {
      server.body = jsonEncode({
        'data': {
          'delete_review': {
            '__typename': 'OperationInfo',
            'messages': [{'message': 'Nu există recenzie'}],
          },
        },
      });
      final result = await ReviewService.deleteReview(stationId: 1);
      expect(result.success, false);
      expect(result.error, 'Nu există recenzie');
    });
  });
}

/// Redirects all requests to api.radiocrestin.ro to the fake local server.
class _RedirectOverrides extends HttpOverrides {
  _RedirectOverrides(this.baseUrl);
  final String baseUrl;
  late final Uri _base = Uri.parse(baseUrl);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    return _RedirectingClient(client, _base);
  }
}

class _RedirectingClient implements HttpClient {
  _RedirectingClient(this._inner, this._base);
  final HttpClient _inner;
  final Uri _base;

  Uri _redirect(Uri url) {
    if (url.host == 'api.radiocrestin.ro') {
      return url.replace(
        scheme: _base.scheme,
        host: _base.host,
        port: _base.port,
      );
    }
    return url;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _inner.openUrl(method, _redirect(url));

  // Forward everything else.
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) =>
      _inner.maxConnectionsPerHost = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);
  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;
  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)? cb) =>
      _inner.badCertificateCallback = cb;
  @override
  set connectionFactory(
      Future<ConnectionTask<Socket>> Function(
              Uri url, String? proxyHost, int? proxyPort)?
          f) {
    _inner.connectionFactory = f;
  }
  @override
  void close({bool force = false}) => _inner.close(force: force);
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _inner.delete(host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _inner.deleteUrl(_redirect(url));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _inner.get(host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => _inner.getUrl(_redirect(url));
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _inner.head(host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _inner.headUrl(_redirect(url));
  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      _inner.open(method, host, port, path);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _inner.patch(host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _inner.patchUrl(_redirect(url));
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _inner.post(host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _inner.postUrl(_redirect(url));
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _inner.put(host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => _inner.putUrl(_redirect(url));
}
