import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'live_hls.dart';
import 'media.g.dart';
import 'network_conditions.dart';
import 'station_catalog.dart';

/// A request the server answered, or tried to.
class ServedRequest {
  ServedRequest(this.origin, this.path, this.station, this.at);

  final Origin origin;
  final String path;

  /// The station whose stream it was for, if any.
  final String? station;
  final DateTime at;

  /// Response body bytes sent so far; grows while a stream plays.
  int bytesSent = 0;

  bool get isMedia => origin == Origin.hls || origin == Origin.mp3;
}

/// Everything the app reaches over the network, served from the test
/// process on the device's loopback: the REST API, the live HLS origin,
/// the stations' MP3 servers, images and the internet probes, each behind
/// the [conditions] a test sets.
class FakeRadioServer {
  FakeRadioServer._(this._server)
      : catalog = StationCatalog('http://127.0.0.1:${_server.port}') {
    _server.listen(_handle);
  }

  static Future<FakeRadioServer> start() async => FakeRadioServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final StationCatalog catalog;
  final NetworkConditions conditions = NetworkConditions();
  final List<ServedRequest> requests = [];
  final Map<String, LiveHlsStream> _hls = {
    for (final station in Stations.all) station.slug: LiveHlsStream(),
  };

  String get baseUrl => catalog.baseUrl;
  String get apiBaseUrl => '$baseUrl/api/v1';
  Uri get internetProbeUrl => Uri.parse('$baseUrl/probe/generate_204');

  /// The live HLS stream of [station].
  LiveHlsStream hls(FakeStation station) => _hls[station.slug]!;

  /// Media bytes sent for [station] since [since].
  int mediaBytesSent(FakeStation station, {required DateTime since}) =>
      requests
          .where((r) =>
              r.isMedia && r.station == station.slug && !r.at.isBefore(since))
          .fold(0, (sum, r) => sum + r.bytesSent);

  /// Back to a healthy network and live streams, between tests.
  void reset() {
    conditions.restore();
    for (final stream in _hls.values) {
      stream.unfreeze();
    }
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final origin = _originOf(path);
    final served = ServedRequest(origin, path, _stationOf(request.uri, origin),
        DateTime.now());
    requests.add(served);
    // The raw socket lets a test drop a connection mid-body, as a real
    // network does, which HttpResponse cannot once headers are out.
    final socket = await request.response.detachSocket(writeHeaders: false);
    final connection = _Connection(socket, served, conditions);
    try {
      if (!await _arrive(connection)) return;
      await _route(request.uri, connection);
    } catch (_) {
      // The link went down mid-body, or the app hung up: a switch, a
      // pause, a timeout.
      connection.drop();
    }
  }

  Origin _originOf(String path) {
    if (path.startsWith('/hls/')) return Origin.hls;
    if (path.startsWith('/mp3/')) return Origin.mp3;
    if (path.startsWith('/images/')) return Origin.images;
    if (path.startsWith('/probe/')) return Origin.internetProbe;
    return Origin.api;
  }

  String? _stationOf(Uri uri, Origin origin) {
    final segments = uri.pathSegments;
    if (segments.length < 2) return null;
    if (origin == Origin.hls) return segments[1];
    if (origin == Origin.mp3) return segments[1].replaceAll('.mp3', '');
    return null;
  }

  /// Applies the link's latency and outage before the response; false when
  /// the request failed there.
  Future<bool> _arrive(_Connection connection) async {
    final origin = connection.served.origin;
    while (true) {
      await conditions.whileSilent(origin);
      final latency = conditions.linkTo(origin).latency;
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      switch (conditions.linkTo(origin).outage) {
        case Outage.refused:
          connection.drop();
          return false;
        case Outage.serverError:
          await connection.status(HttpStatus.serviceUnavailable);
          return false;
        case Outage.notFound:
          await connection.status(HttpStatus.notFound);
          return false;
        case Outage.silent:
          continue;
        case null:
          return true;
      }
    }
  }

  Future<void> _route(Uri uri, _Connection connection) {
    switch (connection.served.origin) {
      case Origin.api:
        return _api(uri, connection);
      case Origin.hls:
        return _hlsRequest(uri, connection);
      case Origin.mp3:
        return _mp3Stream(connection);
      case Origin.images:
        return connection.send(
            base64Decode(thumbnailPngBase64), 'image/png');
      case Origin.internetProbe:
        return connection.status(HttpStatus.noContent);
    }
  }

  Future<void> _api(Uri uri, _Connection connection) {
    final path = uri.path;
    final body = switch (path) {
      _ when path.startsWith('/api/v1/share-links/') =>
        catalog.shareLinkResponse(uri.pathSegments[3]),
      '/api/v1/stations' => catalog.stationsResponse(),
      '/api/v1/stations-metadata' => catalog.metadataResponse(),
      '/api/v1/private-stations' => {
          'data': {'stations': <Object>[]},
        },
      '/api/v1/stations-metadata-history' => {
          'data': {'stations_metadata_history': null},
        },
      '/api/v1/devices/register/' => {'data': <String, Object>{}},
      _ => null,
    };
    if (body == null) return connection.status(HttpStatus.notFound);
    return connection.send(
        utf8.encode(jsonEncode(body)), 'application/json; charset=utf-8');
  }

  Future<void> _hlsRequest(Uri uri, _Connection connection) {
    final stream = _hls[connection.served.station];
    final file = uri.pathSegments.last;
    if (stream == null) return connection.status(HttpStatus.notFound);
    if (file.endsWith('.m3u8')) {
      return connection.send(
          utf8.encode(stream.playlist()), 'application/vnd.apple.mpegurl');
    }
    final sequence = int.tryParse(file.replaceAll('.aac', ''));
    if (sequence == null || sequence > stream.liveSequence()) {
      return connection.status(HttpStatus.notFound);
    }
    return connection.send(stream.segment(sequence), 'audio/aac');
  }

  /// An endless MP3 stream at its bitrate, after a 4 s burst, as Icecast
  /// sends it: no length, the body ends when the connection does.
  Future<void> _mp3Stream(_Connection connection) async {
    final audio = base64Decode(mp3LoopBase64);
    const bytesPerSecond = 32000 ~/ 8;
    var offset = 0;
    List<int> next(int length) {
      final chunk = BytesBuilder(copy: false);
      while (chunk.length < length) {
        final end = min(audio.length, offset + length - chunk.length);
        chunk.add(Uint8List.sublistView(audio, offset, end));
        offset = end % audio.length;
      }
      return chunk.takeBytes();
    }

    connection.head(HttpStatus.ok, {
      'Content-Type': 'audio/mpeg',
      'icy-br': '32',
      'Cache-Control': 'no-cache',
    });
    await connection.write(next(bytesPerSecond * 4));
    while (connection.isOpen) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await connection.write(next(bytesPerSecond ~/ 4));
    }
  }
}

/// One request's connection, answered by hand on its raw socket.
class _Connection {
  _Connection(this._socket, this.served, this._conditions) {
    _socket.listen((_) {}, onDone: _close, onError: (_) => _close());
  }

  final Socket _socket;
  final ServedRequest served;
  final NetworkConditions _conditions;
  bool _open = true;

  /// Whether the app still holds the connection.
  bool get isOpen => _open;

  void _close() => _open = false;

  void head(int status, Map<String, String> headers) {
    final lines = [
      'HTTP/1.1 $status ${_reasons[status] ?? 'Status'}',
      for (final MapEntry(:key, :value) in headers.entries) '$key: $value',
      'Connection: close',
      '',
      '',
    ];
    _socket.add(latin1.encode(lines.join('\r\n')));
  }

  /// A response without a body.
  Future<void> status(int status) async {
    head(status, {'Content-Length': '0'});
    await _end();
  }

  /// A whole response with [body].
  Future<void> send(List<int> body, String contentType) async {
    head(HttpStatus.ok, {
      'Content-Type': contentType,
      'Content-Length': '${body.length}',
      'Cache-Control': 'no-store',
    });
    await write(body);
    await _end();
  }

  /// Writes [bytes] in slices, each meeting the link as it is then: a link
  /// that goes down drops the connection mid-body, a silent one stalls it,
  /// a capped one paces it.
  Future<void> write(List<int> bytes) async {
    const slice = 4096;
    for (var start = 0; start < bytes.length; start += slice) {
      await _conditions.whileSilent(served.origin);
      final link = _conditions.linkTo(served.origin);
      if (link.outage != null) throw const SocketException('link down');
      if (!_open) throw const SocketException('closed by the app');
      final end = min(bytes.length, start + slice);
      _socket.add(bytes.sublist(start, end));
      await _socket.flush();
      served.bytesSent += end - start;
      final cap = link.bytesPerSecond;
      if (cap != null) {
        await Future<void>.delayed(
            Duration(microseconds: (end - start) * 1000000 ~/ cap));
      }
    }
  }

  /// Breaks the connection without a word: a reset, no route.
  void drop() {
    _open = false;
    _socket.destroy();
  }

  Future<void> _end() async {
    await _socket.flush();
    await _socket.close();
    _open = false;
  }

  static const _reasons = {
    200: 'OK',
    204: 'No Content',
    404: 'Not Found',
    503: 'Service Unavailable',
  };
}
