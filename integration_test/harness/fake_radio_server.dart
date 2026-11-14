import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'live_hls.dart';
import 'media.g.dart';
import 'network_conditions.dart';
import 'station_catalog.dart';

/// An admin's own announcement icon, as the backend stores an uploaded SVG.
const iconSvg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
    '<rect width="24" height="24" rx="6" fill="#0F6E63"/>'
    '<circle cx="12" cy="12" r="6" fill="#ffffff"/></svg>';

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

  /// The body the app posted, if any.
  String? body;

  /// The query and the `If-None-Match` header the app sent.
  Map<String, String> query = const {};
  String? ifNoneMatch;

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

  /// What `GET /announcements/` lists, as the API's JSON items; empty
  /// unless a test sets it.
  final List<Map<String, Object?>> announcements = [];

  /// The list's `settings`.
  Map<String, Object?> announcementSettings = defaultAnnouncementSettings;

  /// How long `GET /announcements/` takes to answer; the rest of the API
  /// stays fast.
  Duration announcementListDelay = Duration.zero;

  static const defaultAnnouncementSettings = {
    'rotation_mode': 'fixed',
    'max_per_load': 5,
  };

  /// Forms by slug: their question and options, for the form page.
  final Map<String, ({String question, List<String> options})> forms = {};

  /// The events the app reported to `POST /announcements/events/`.
  final List<Map<String, Object?>> announcementEvents = [];
  final Map<String, LiveHlsStream> _hls = {
    for (final station in Stations.all) station.slug: LiveHlsStream(),
  };

  String get baseUrl => catalog.baseUrl;
  String get host => InternetAddress.loopbackIPv4.address;
  String get apiBaseUrl => '$baseUrl/api/v1';
  Uri get internetProbeUrl => Uri.parse('$baseUrl/probe/generate_204');

  /// The live HLS stream of [station].
  LiveHlsStream hls(FakeStation station) => _hls[station.slug]!;

  /// Media bytes sent for [station] since [since], from [origin] only when
  /// given.
  int mediaBytesSent(
    FakeStation station, {
    required DateTime since,
    Origin? origin,
  }) =>
      requests
          .where((r) =>
              r.isMedia &&
              (origin == null || r.origin == origin) &&
              r.station == station.slug &&
              !r.at.isBefore(since))
          .fold(0, (sum, r) => sum + r.bytesSent);

  /// Back to a healthy network and live streams, between tests.
  void reset() {
    conditions.restore();
    announcements.clear();
    announcementEvents.clear();
    announcementSettings = defaultAnnouncementSettings;
    announcementListDelay = Duration.zero;
    forms.clear();
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
    served
      ..query = request.uri.queryParameters
      ..ifNoneMatch = request.headers.value('if-none-match');
    if (request.method == 'POST') {
      served.body = await utf8.decoder.bind(request).join();
    }
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
        if (uri.path.endsWith('.svg')) {
          return connection.send(utf8.encode(iconSvg), 'image/svg+xml');
        }
        return connection.send(
            base64Decode(thumbnailPngBase64), 'image/png');
      case Origin.internetProbe:
        return connection.status(HttpStatus.noContent);
    }
  }

  Future<void> _api(Uri uri, _Connection connection) {
    final path = uri.path;
    if (path == '/api/v1/announcements/') return _announcementList(connection);
    if (path.startsWith('/api/v1/forms/') && path.endsWith('/page/')) {
      return connection.send(
          utf8.encode(_formPage(uri.pathSegments[3],
              dark: uri.queryParameters['theme'] == 'dark')),
          'text/html; charset=utf-8');
    }
    final body = switch (path) {
      '/api/v1/announcements/events/' =>
        _acceptEvents(connection.served.body),
      _ when path.startsWith('/api/v1/announcements/') => announcements
          .where((a) => a['slug'] == uri.pathSegments[3])
          .firstOrNull,
      _ when path.startsWith('/api/v1/share-links/') =>
        catalog.shareLinkResponse(uri.pathSegments[3]),
      '/api/v1/stations' => catalog.stationsResponse(),
      '/api/v1/stations-metadata' => catalog.metadataResponse(),
      '/api/v1/station-playlist' =>
        catalog.stationPlaylistResponse(uri.queryParameters['station_slug']),
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

  /// The list as the API caches it: no page markdown (it comes with the
  /// single announcement), an ETag, and 304 when the app has it already.
  /// It is the list as it was when the request arrived, sent after
  /// [announcementListDelay].
  Future<void> _announcementList(_Connection connection) async {
    final body = utf8.encode(jsonEncode({
      'settings': announcementSettings,
      'announcements': [
        for (final item in announcements)
          {
            ...item,
            if (item['page'] case final Map<String, Object?> page)
              'page': {...page}
                ..remove('markdown')
                ..remove('embeds'),
          },
      ],
    }));
    await Future<void>.delayed(announcementListDelay);
    final hash = body.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff);
    final etag = '"${body.length}-$hash"';
    if (connection.served.ifNoneMatch == etag) {
      return connection.status(HttpStatus.notModified);
    }
    return connection.send(body, 'application/json; charset=utf-8',
        headers: {'ETag': etag});
  }

  /// A form page that tells the app it is ready, as the backend's does,
  /// in the spec's card colors for the theme asked.
  String _formPage(String slug, {required bool dark}) {
    final form = forms[slug] ?? (question: 'Form $slug', options: ['A', 'B']);
    final (surface, text, border) = dark
        ? ('#1A1A1A', '#EDEDED', '#2F2F2F')
        : ('#FFFFFF', '#1A1A1A', '#E7E7E7');
    return '''
<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { margin: 0; padding: 4px 20px; background: $surface; color: $text;
         font-family: system-ui, -apple-system, Roboto, sans-serif; }
  .option { border: 1px solid $border; border-radius: 12px; padding: 14px;
            margin: 10px 0; font-size: 15px; }
</style></head><body>
<h2 id="title">${form.question}</h2>
${form.options.map((option) => '<div class="option">$option</div>').join()}
<script>
  var msg = JSON.stringify({type: "rc-form", event: "ready", slug: "$slug"});
  if (window.RadioCrestinForm) window.RadioCrestinForm.postMessage(msg);
</script>
</body></html>''';
  }

  /// Keeps the events of an events report; the app sends JSON, the
  /// website text/plain, both parsed whatever the Content-Type.
  Map<String, Object?> _acceptEvents(String? body) {
    final events =
        (jsonDecode(body ?? '{}') as Map)['events'] as List? ?? [];
    announcementEvents.addAll(events.cast<Map<String, Object?>>());
    return {'status': 'ok', 'accepted': events.length, 'country': 'RO'};
  }

  Future<void> _hlsRequest(Uri uri, _Connection connection) {
    final stream = _hls[connection.served.station];
    final file = uri.pathSegments.last;
    if (stream == null) return connection.status(HttpStatus.notFound);
    if (file.endsWith('.m3u8')) {
      final start = _startVariants[file];
      if (start == null) return connection.status(HttpStatus.notFound);
      return connection.send(utf8.encode(stream.playlist(start: start)),
          'application/vnd.apple.mpegurl');
    }
    final sequence = int.tryParse(file.replaceAll('.aac', ''));
    if (sequence == null || sequence > stream.liveSequence()) {
      return connection.status(HttpStatus.notFound);
    }
    return connection.send(stream.segment(sequence), 'audio/aac');
  }

  /// The playlists the origin publishes, by where they start the player:
  /// the live one 18 s behind live, and the app's 2- and 5-minute starts.
  static const _startVariants = {
    'index.m3u8': Duration(seconds: 18),
    'index-2m.m3u8': Duration(minutes: 2),
    'index-5m.m3u8': Duration(minutes: 5),
  };

  /// An endless 128 kb/s MP3 stream at its bitrate, after Icecast's
  /// default 64 KB burst on connect: no length, the body ends when the
  /// connection does.
  Future<void> _mp3Stream(_Connection connection) async {
    final audio = base64Decode(mp3LoopBase64);
    const bytesPerSecond = 128000 ~/ 8;
    const burst = 65536;
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
      'icy-br': '128',
      'Cache-Control': 'no-cache',
    });
    await connection.write(next(burst));
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
  Future<void> send(
    List<int> body,
    String contentType, {
    Map<String, String> headers = const {},
  }) async {
    head(HttpStatus.ok, {
      'Content-Type': contentType,
      'Content-Length': '${body.length}',
      'Cache-Control': 'no-store',
      ...headers,
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
    304: 'Not Modified',
    404: 'Not Found',
    503: 'Service Unavailable',
  };
}
