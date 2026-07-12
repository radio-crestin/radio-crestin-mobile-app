import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Timeouts and stall detection for the app's direct HTTP traffic.
///
/// Motivation: a backend that ACCEPTS a connection but then goes silent
/// (sends nothing, or trickles) is not caught by connect timeouts — the
/// request can hold its caller for minutes. Small JSON requests get a
/// tight total-duration bound; larger transfers (image downloads) get
/// idle-stall semantics instead, so a slow-but-flowing download survives
/// while a genuinely stalled one is cancelled.
///
/// Callers that own an [http.Client] should `close()` it in a `finally`
/// (see [ImageCacheService]) so a cancelled transfer also releases its
/// socket instead of piling up half-open connections against the backend.
class HttpStallGuard {
  /// Total-duration bound for small JSON REST calls (station metadata,
  /// song history, reviews, GraphQL). Payloads are a few KB — anything
  /// that takes longer than this is a stalled backend, not a slow payload.
  static const Duration restApiTimeout = Duration(seconds: 10);

  /// Time allowed for a streamed request to produce response HEADERS.
  /// Separate from the body stall guard: headers arriving is the signal
  /// the backend is alive at all.
  static const Duration responseHeadersTimeout = Duration(seconds: 8);

  /// Idle bound for streamed downloads: no bytes for this long → stalled.
  static const Duration downloadIdleTimeout = Duration(seconds: 5);

  /// Hard cap for a full download — generous (vs. the idle bound) so a
  /// slow-but-flowing large image still finishes, while an endless
  /// trickle cannot hold a socket forever.
  static const Duration downloadTotalTimeout = Duration(seconds: 30);

  /// Wraps [source] with idle-stall detection: if no chunk arrives within
  /// [idleTimeout] the stream errors with a [TimeoutException] and closes,
  /// which cancels the upstream subscription (releasing the HTTP response).
  static Stream<List<int>> guard(
    Stream<List<int>> source, {
    required Duration idleTimeout,
  }) {
    return source.timeout(idleTimeout, onTimeout: (sink) {
      sink.addError(TimeoutException(
        'stream stalled: no data for ${idleTimeout.inSeconds}s',
        idleTimeout,
      ));
      sink.close();
    });
  }

  /// Collects [source] into bytes with both stall semantics: errors when
  /// no chunk arrives for [idleTimeout], or when the whole transfer
  /// exceeds [totalTimeout]. On the total timeout the abandoned
  /// subscription is only released when the owning client is closed —
  /// close the client in a `finally`.
  static Future<Uint8List> readBytes(
    Stream<List<int>> source, {
    Duration idleTimeout = downloadIdleTimeout,
    Duration totalTimeout = downloadTotalTimeout,
  }) {
    Future<Uint8List> collect() async {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in guard(source, idleTimeout: idleTimeout)) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    }

    return collect().timeout(totalTimeout);
  }
}

/// [http.BaseClient] wrapper that bounds every request it sends: headers
/// must arrive within [headersTimeout] and the response body must never
/// go idle for [bodyIdleTimeout]. Used for the GraphQL [HttpLink] client
/// so no GraphQL round-trip can hang on a silent backend.
class TimeoutHttpClient extends http.BaseClient {
  TimeoutHttpClient(
    this._inner, {
    this.headersTimeout = HttpStallGuard.restApiTimeout,
    this.bodyIdleTimeout = HttpStallGuard.restApiTimeout,
  });

  final http.Client _inner;
  final Duration headersTimeout;
  final Duration bodyIdleTimeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request).timeout(headersTimeout);
    return http.StreamedResponse(
      HttpStallGuard.guard(response.stream, idleTimeout: bodyIdleTimeout),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
