import 'dart:async';

/// A server the app talks to, as the fake radio server stands in for it.
enum Origin {
  /// The Radio Crestin REST API: stations, metadata, device registration.
  api,

  /// The live HLS origin: playlists and segments.
  hls,

  /// The stations' own Icecast-style MP3 servers.
  mp3,

  /// Station thumbnails and song covers.
  images,

  /// The endpoints that tell the app whether the internet answers.
  internetProbe,
}

/// How an unreachable origin fails a request.
enum Outage {
  /// The connection breaks at once, as with no route or a reset.
  refused,

  /// The connection opens, then nothing arrives until the outage ends:
  /// a stalled link or a server that hangs.
  silent,

  /// The server answers `503 Service Unavailable`.
  serverError,

  /// The server answers `404 Not Found`.
  notFound,
}

/// What requests to one origin meet on their way.
class Link {
  const Link({this.latency = Duration.zero, this.bytesPerSecond, this.outage});

  /// A fast, healthy link.
  static const healthy = Link();

  /// Delay before the response starts, as a round trip.
  final Duration latency;

  /// Throughput cap of a response body; null for no cap.
  final int? bytesPerSecond;

  /// Why the origin is unreachable; null while it is reachable.
  final Outage? outage;
}

/// The network the app sees, set by each test and read by the server for
/// every request and, while a response streams, for every chunk of it.
class NetworkConditions {
  final Map<Origin, Link> _links = {};
  final StreamController<void> _changes = StreamController.broadcast();

  /// The link to [origin].
  Link linkTo(Origin origin) => _links[origin] ?? Link.healthy;

  /// Sets the link to each of [origins] (every origin when null).
  void set(Link link, {Iterable<Origin>? origins}) {
    for (final origin in origins ?? Origin.values) {
      _links[origin] = link;
    }
    _changes.add(null);
  }

  /// Every origin unreachable, the internet probes included: airplane
  /// mode, a tunnel, a dead router.
  void goOffline() => set(const Link(outage: Outage.refused));

  /// Every origin healthy again.
  void restore() {
    _links.clear();
    _changes.add(null);
  }

  /// Waits until the link to [origin] is no longer [Outage.silent].
  Future<void> whileSilent(Origin origin) async {
    while (linkTo(origin).outage == Outage.silent) {
      await _changes.stream.first;
    }
  }
}
