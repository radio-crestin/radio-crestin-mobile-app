import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:flutter_test/flutter_test.dart' show pumpEventQueue;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/services/private_stations_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'station_factory.dart';

/// Controlled time for the metadata pipeline.
///
/// [wait] completes only when [advance] moves the clock past its deadline,
/// so retries, follow-ups and slow responses run in a deterministic order.
class FakeClock {
  FakeClock(DateTime start) : _now = start.toUtc();

  DateTime _now;
  int _sequence = 0;
  final List<_Waiter> _waiters = [];

  DateTime call() => _now;
  DateTime get now => _now;
  int get epoch => _now.millisecondsSinceEpoch ~/ 1000;

  /// Waits for [duration] of fake time.
  Future<void> wait(Duration duration) {
    final waiter = _Waiter(_now.add(duration), _sequence++);
    _waiters.add(waiter);
    return waiter.completer.future;
  }

  /// Moves time forward by [duration], completing every wait that falls due
  /// in order and letting the code it releases run before the next one.
  Future<void> advance(Duration duration) async {
    final target = _now.add(duration);
    while (true) {
      await pumpEventQueue(times: 200);
      final due = _waiters.where((w) => !w.at.isAfter(target)).toList()
        ..sort((a, b) =>
            a.at == b.at ? a.order.compareTo(b.order) : a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final next = due.first;
      _waiters.remove(next);
      if (next.at.isAfter(_now)) _now = next.at;
      next.completer.complete();
    }
    _now = target;
    await pumpEventQueue(times: 200);
  }

  /// Runs everything that is ready without moving time.
  Future<void> settle() => advance(Duration.zero);
}

class _Waiter {
  _Waiter(this.at, this.order);
  final DateTime at;
  final int order;
  final Completer<void> completer = Completer<void>();
}

/// A song as the API returns it.
class FakeSong {
  const FakeSong(
    this.id,
    this.title, {
    this.artist,
    this.artistId = 1,
    this.thumbnailUrl,
  });

  final int id;
  final String title;
  final String? artist;
  final int artistId;
  final String? thumbnailUrl;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': title,
        'thumbnail_url': thumbnailUrl,
        'artist': artist == null
            ? null
            : {'id': artistId, 'name': artist, 'thumbnail_url': null},
      };
}

/// One `stations_now_playing_history` row.
class FakeRow {
  FakeRow({
    required this.stationId,
    required this.timestamp,
    required this.song,
    required this.listeners,
    required this.insertedAt,
    required this.order,
    this.songStartedAt,
  });

  final int stationId;

  /// Row time: drives diff visibility and API order.
  final DateTime timestamp;

  /// Backend B3/R10 `song_started_at`; null for legacy rows.
  final DateTime? songStartedAt;
  final FakeSong? song;
  final int listeners;

  /// The row is invisible to every endpoint before this instant (ingestion).
  final DateTime insertedAt;
  final int order;

  int compareTo(FakeRow other) => timestamp == other.timestamp
      ? order.compareTo(other.order)
      : timestamp.compareTo(other.timestamp);
}

class _FakeStation {
  _FakeStation(this.id, this.slug, this.title, {required this.hls});
  final int id;
  final String slug;
  final String title;

  /// Streams: the HLS playlist first, then the MP3 fallback.
  final bool hls;
}

class _EdgeCopy {
  _EdgeCopy(this.body, this.generatedAt, this.cachedAt, this.maxAge);
  final String body;
  final DateTime generatedAt;
  final DateTime cachedAt;

  /// Null: immutable (today's `/stations-metadata`).
  final Duration? maxAge;
}

/// A faithful fake of the metadata backend and its edge cache, served through
/// a [MockClient] so tests drive the production [StationDataService].
///
/// Mirrors `/stations-metadata` Mode 1/2 (`queries.py`), the history
/// endpoint (window, "first row of each song run" dedupe, the `to ≤ now + 2`
/// check, `Last-Modified` = generation time) and the GraphQL station list.
/// Toggles model today's backend and the fixed one (B3/R10, B4).
class FakeMetadataBackend {
  FakeMetadataBackend(this.clock);

  final FakeClock clock;
  final List<_FakeStation> _stations = [];
  final List<FakeRow> _rows = [];
  final Map<String, _EdgeCopy> _edge = {};
  final Map<String, List<int>> _failures = {};

  /// Every request, in order.
  final List<Uri> requests = [];

  /// Cloudflare: `/stations-metadata` copies frozen per URL, history copies
  /// kept [historyMaxAge].
  bool edgeCache = true;
  Duration historyMaxAge = const Duration(seconds: 60);

  /// R10.1: rows expose `coalesce(song_started_at, timestamp)`.
  bool exposeSongStart = true;

  /// R10.2: the history dedupe is seeded with the newest row before `from`.
  bool seedHistoryDedupe = false;

  /// B4: Mode 1 also lists rows up to this long before `changes_from`.
  Duration diffLookback = Duration.zero;

  /// Whether history responses carry `Last-Modified`.
  bool sendLastModified = true;

  /// Awaited before a history response is generated (a slow request).
  Future<void> Function(Uri url)? beforeHistoryResponse;

  /// Awaited before a `/stations-metadata` response is generated.
  Future<void> Function(Uri url)? beforeMetadataResponse;

  /// The server clock minus the device clock ([clock]); only the history
  /// endpoint's `to ≤ now + 2` check reads it.
  Duration serverClockOffset = Duration.zero;

  late final http.Client client = MockClient(_handle);

  /// GraphQL client for the station list, served by this backend.
  late final GraphQLClient graphqlClient = GraphQLClient(
    link: HttpLink('https://example.com/graphql', httpClient: client),
    cache: GraphQLCache(),
    defaultPolicies: DefaultPolicies(
      query: Policies(
        fetch: FetchPolicy.networkOnly,
        cacheReread: CacheRereadPolicy.ignoreAll,
      ),
    ),
  );

  List<Uri> get historyRequests =>
      requests.where((u) => u.path.endsWith('-history')).toList();

  List<Uri> get metadataRequests =>
      requests.where((u) => u.path.endsWith('/stations-metadata')).toList();

  List<Uri> get graphqlRequests =>
      requests.where((u) => u.path.endsWith('/graphql')).toList();

  List<Uri> get privateRequests =>
      requests.where((u) => u.path.endsWith('/private-stations')).toList();

  /// [hls]: the station's preferred stream is [hlsUrlOf] (MP3 fallback).
  void addStation(int id, String slug, String title, {bool hls = false}) =>
      _stations.add(_FakeStation(id, slug, title, hls: hls));

  /// The HLS playlist URL of an [addStation] with `hls: true`.
  static String hlsUrlOf(String slug) =>
      'https://hls.example.com/hls/$slug/index.m3u8';

  /// The MP3 stream URL every station has.
  static String mp3UrlOf(String slug) =>
      'https://stream.example.com/$slug/stream.mp3';

  /// A song change at [startedAt], visible after [ingestLag] (or at
  /// [insertedAt]).
  FakeRow songChange(
    int stationId,
    DateTime startedAt,
    FakeSong? song, {
    int listeners = 10,
    Duration ingestLag = Duration.zero,
    DateTime? insertedAt,
    DateTime? songStartedAt,
  }) =>
      _addRow(FakeRow(
        stationId: stationId,
        timestamp: startedAt.toUtc(),
        songStartedAt: songStartedAt?.toUtc(),
        song: song,
        listeners: listeners,
        insertedAt: (insertedAt ?? startedAt.add(ingestLag)).toUtc(),
        order: _rows.length,
      ));

  /// A listener-count report at [at] for the song still running: a row dated
  /// at the report whose `song_started_at` is that song's start (B3/R10).
  FakeRow listenerReport(
    int stationId,
    DateTime at, {
    required FakeSong? song,
    required DateTime songStartedAt,
    int listeners = 11,
    Duration ingestLag = Duration.zero,
  }) =>
      songChange(stationId, at, song,
          listeners: listeners,
          ingestLag: ingestLag,
          songStartedAt: songStartedAt);

  /// The next [count] requests whose path ends with [pathSuffix] fail with
  /// [status].
  void failNext(String pathSuffix, {int status = 500, int count = 1}) =>
      _failures
          .putIfAbsent(pathSuffix, () => [])
          .addAll(List.filled(count, status));

  FakeRow _addRow(FakeRow row) {
    _rows.add(row);
    return row;
  }

  /// A [StationDataService] wired to this backend and [clock].
  StationDataService newService(SharedPreferences prefs) => StationDataService(
        graphqlClient: graphqlClient,
        privateStationsService: PrivateStationsService(
          httpClient: client,
          prefs: prefs,
          deviceIdProvider: () => 'device-1',
        ),
        httpClient: client,
        clock: clock.call,
        wait: clock.wait,
      );

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request.url);
    final failure = _takeFailure(request.url.path);
    if (failure != null) return http.Response('error', failure);
    final path = request.url.path;
    if (request.method == 'POST' && path.endsWith('/graphql')) {
      return _json(_graphqlStations());
    }
    if (path.endsWith('/stations-metadata-history')) {
      await beforeHistoryResponse?.call(request.url);
      return _cached(request.url, historyMaxAge, _history);
    }
    if (path.endsWith('/stations-metadata')) {
      await beforeMetadataResponse?.call(request.url);
      return _cached(request.url, null, _metadata);
    }
    if (path.endsWith('/private-stations')) {
      // Transient: the private service keeps trying on every eligible sync,
      // so tests can observe which syncs fetched it.
      return http.Response('unavailable', 503);
    }
    return http.Response('not found', 404);
  }

  int? _takeFailure(String path) {
    for (final entry in _failures.entries) {
      if (path.endsWith(entry.key) && entry.value.isNotEmpty) {
        return entry.value.removeAt(0);
      }
    }
    return null;
  }

  http.Response _cached(
    Uri url,
    Duration? maxAge,
    Map<String, dynamic> Function(Uri url) generate,
  ) {
    final key = url.toString();
    final now = clock.now;
    final copy = _edge[key];
    final fresh = copy != null &&
        (copy.maxAge == null || now.difference(copy.cachedAt) < copy.maxAge!);
    if (edgeCache && fresh) {
      return _response(copy.body, copy.generatedAt,
          age: now.difference(copy.cachedAt));
    }
    final body = json.encode(generate(url));
    if (edgeCache) _edge[key] = _EdgeCopy(body, now, now, maxAge);
    return _response(body, now);
  }

  http.Response _response(String body, DateTime generatedAt, {Duration? age}) {
    final headers = <String, String>{
      'content-type': 'application/json',
      'date': HttpDate.format(clock.now),
      if (sendLastModified) 'last-modified': HttpDate.format(generatedAt),
      if (age != null) 'age': '${age.inSeconds}',
    };
    return http.Response(body, 200, headers: headers);
  }

  http.Response _json(Map<String, dynamic> body) =>
      http.Response(json.encode(body), 200,
          headers: {'content-type': 'application/json'});

  Iterable<FakeRow> _visible(int stationId) => _rows.where(
      (r) => r.stationId == stationId && !r.insertedAt.isAfter(clock.now));

  FakeRow? _newestAtOrBefore(int stationId, DateTime t) {
    final rows = _visible(stationId).where((r) => !r.timestamp.isAfter(t));
    if (rows.isEmpty) return null;
    return rows.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
  }

  DateTime _exposed(FakeRow row) =>
      exposeSongStart ? (row.songStartedAt ?? row.timestamp) : row.timestamp;

  Map<String, dynamic> _nowPlaying(FakeRow row) => {
        'timestamp': _exposed(row).toIso8601String(),
        'listeners': row.listeners,
        'song': row.song?.toJson(),
      };

  /// `/stations-metadata`: Mode 2 (newest row ≤ T per station), or Mode 1
  /// with `changes_from_timestamp=C` (only stations with a row in (C, T]).
  Map<String, dynamic> _metadata(Uri url) {
    final t = _instant(url.queryParameters['timestamp']) ?? clock.now;
    final c = _instant(url.queryParameters['changes_from_timestamp']);
    final items = <Map<String, dynamic>>[];
    for (final station in _stations) {
      if (c != null && !_changedIn(station.id, c.subtract(diffLookback), t)) {
        continue;
      }
      final row = _newestAtOrBefore(station.id, t);
      items.add({
        'id': station.id,
        'uptime': {
          'is_up': true,
          'latency_ms': 100,
          'timestamp': t.toIso8601String(),
        },
        'now_playing': row == null ? null : _nowPlaying(row),
      });
    }
    return {
      'data': {'stations_metadata': items}
    };
  }

  bool _changedIn(int stationId, DateTime after, DateTime until) =>
      _visible(stationId).any(
          (r) => r.timestamp.isAfter(after) && !r.timestamp.isAfter(until));

  /// `/stations-metadata-history`: rows in [from, to], first of each song
  /// run, API order (timestamp, insertion).
  Map<String, dynamic> _history(Uri url) {
    final q = url.queryParameters;
    final to = _instant(q['to_timestamp']) ?? clock.now;
    final serverNow = clock.now.add(serverClockOffset);
    if (to.isAfter(serverNow.add(const Duration(seconds: 2)))) {
      return {
        'data': null,
        'errors': [
          {'message': 'to_timestamp cannot be in the future'}
        ],
      };
    }
    final from = _instant(q['from_timestamp']) ??
        clock.now.subtract(const Duration(hours: 1));
    final station = _stations.firstWhere((s) => s.slug == q['station_slug']);
    final rows = _visible(station.id)
        .where((r) => !r.timestamp.isBefore(from) && !r.timestamp.isAfter(to))
        .toList()
      ..sort((a, b) => a.compareTo(b));
    final seed = seedHistoryDedupe
        ? _newestAtOrBefore(
            station.id, from.subtract(const Duration(microseconds: 1)))
        : null;
    var hasPrevious = seed != null;
    var previous = seed?.song?.id;
    final entries = <Map<String, dynamic>>[];
    for (final row in rows) {
      final songId = row.song?.id;
      if (hasPrevious && songId == previous) continue;
      hasPrevious = true;
      previous = songId;
      entries.add(_nowPlaying(row));
    }
    return {
      'data': {
        'stations_metadata_history': {
          'station_id': station.id,
          'station_slug': station.slug,
          'station_title': station.title,
          'from_timestamp': from.millisecondsSinceEpoch ~/ 1000,
          'to_timestamp': to.millisecondsSinceEpoch ~/ 1000,
          'count': entries.length,
          'history': entries,
        }
      }
    };
  }

  Map<String, dynamic> _graphqlStations() => {
        'data': Query$GetStations(
          stations: [
            for (final s in _stations)
              StationFactory.createRawStation(
                id: s.id,
                slug: s.slug,
                title: s.title,
                thumbnailUrl: null,
                stationStreams: [
                  if (s.hls)
                    Query$GetStations$stations$station_streams(
                        order: 0, type: 'HLS', stream_url: hlsUrlOf(s.slug)),
                  Query$GetStations$stations$station_streams(
                      order: 1, type: 'mp3', stream_url: mp3UrlOf(s.slug)),
                ],
              ),
          ],
          station_groups: const [],
        ).toJson(),
      };

  static DateTime? _instant(String? epochSeconds) {
    final value = int.tryParse(epochSeconds ?? '');
    if (value == null || value == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
  }
}

/// The player-side hooks of [StationDataService], settable by tests.
class FakePlayer {
  FakePlayer(this.clock);

  final FakeClock clock;

  /// A frozen audible instant (paused); wins over [latency].
  DateTime? frozenAudible;

  /// Playing: the audible instant trails the clock by this much.
  Duration? latency;

  /// Local live HLS loaded (`isTimeShiftedHlsActive`).
  bool active = false;

  /// The station the player is on (`getPlayingStationId`).
  int? playingId;

  /// `getAudibleInstant`: null while anchoring or not time-shifted.
  DateTime? get audible {
    if (frozenAudible != null) return frozenAudible;
    final l = latency;
    return l == null ? null : clock.now.subtract(l);
  }

  /// Time-shifted HLS of [stationId], heard [latency] behind live.
  void playHls(int stationId, Duration latency) {
    playingId = stationId;
    active = true;
    frozenAudible = null;
    this.latency = latency;
  }

  /// Pauses: the audible instant freezes where it is.
  void pause() => frozenAudible = audible;

  void attach(StationDataService service) {
    service.getAudibleInstant = () => audible;
    service.isTimeShiftedHlsActive = () => active;
    service.getPlayingStationId = () => playingId;
  }
}
