import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:rxdart/rxdart.dart';

import '../constants.dart';
import '../types/playlist_item.dart';
import '../utils/api_utils.dart';

/// Polls the live playlist for a single "playlist" station every 5 seconds.
///
/// GETs `/station-playlist?station_slug=<slug>&timestamp=<ts>` where `ts` is
/// unix-now floored to 5s (see [getRoundedTimestamp5s]) — the endpoint caches
/// on that 5s key. Each successful poll emits the freshly-parsed, order-sorted
/// item list on [updates]; [PlaylistController] reconciles it against what's
/// playing (see [PlaylistReconciler]).
///
/// Suspends itself while the app is backgrounded ([pause]) and resumes on
/// foreground ([resume]) so a hidden playlist page isn't hammering the network.
/// The UI calls [startSync]/[stopSync] on page visibility.
class PlaylistSyncService {
  PlaylistSyncService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _interval = Duration(seconds: 5);
  static const Duration _timeout = Duration(seconds: 5);

  Timer? _timer;
  String? _activeSlug;
  bool _paused = false;
  bool _inFlight = false;

  final PublishSubject<List<PlaylistItem>> _updates =
      PublishSubject<List<PlaylistItem>>();

  /// Emits the full ordered playlist on every successful poll (may be empty).
  Stream<List<PlaylistItem>> get updates => _updates.stream;

  /// The station slug currently being synced, or null when idle.
  String? get activeSlug => _activeSlug;

  bool get isRunning => _timer != null;

  /// Starts polling [stationSlug]. Fetches immediately, then every 5s. Calling
  /// with a different slug switches targets; calling with the same slug while
  /// already running is a no-op.
  void startSync(String stationSlug) {
    if (_activeSlug == stationSlug && _timer != null) return;
    _log('startSync($stationSlug)');
    _activeSlug = stationSlug;
    _paused = false;
    _restartTimer();
    unawaited(_poll());
  }

  /// Stops polling entirely and clears the active target.
  void stopSync() {
    _log('stopSync');
    _timer?.cancel();
    _timer = null;
    _activeSlug = null;
  }

  /// Suspends polling without forgetting the target (app backgrounded).
  void pause() {
    if (_paused) return;
    _log('pause');
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Resumes polling for the active target (app foregrounded). Fetches once
  /// immediately so a change made while backgrounded shows up right away.
  void resume() {
    if (!_paused) return;
    _paused = false;
    if (_activeSlug == null) return;
    _log('resume($_activeSlug)');
    _restartTimer();
    unawaited(_poll());
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => _poll());
  }

  Future<void> _poll() async {
    final slug = _activeSlug;
    if (slug == null || _paused || _inFlight) return;
    _inFlight = true;
    try {
      final ts = getRoundedTimestamp5s();
      final url = '${CONSTANTS.STATION_PLAYLIST_URL}'
          '?station_slug=$slug&timestamp=$ts';
      final response = await _client.get(Uri.parse(url)).timeout(_timeout);
      // A slug switch or stop may have landed during the await.
      if (slug != _activeSlug) return;
      if (response.statusCode != 200) {
        _log('poll HTTP ${response.statusCode} for $slug');
        return;
      }
      final items = parsePlaylistResponse(response.body, stationSlug: slug);
      if (items == null) return; // malformed — keep last known list
      _updates.add(items);
    } catch (e) {
      _log('poll error for $slug: $e');
    } finally {
      _inFlight = false;
    }
  }

  /// Parses a `/station-playlist` response body into an ordered item list.
  ///
  /// Response shape: `{"data":{"stations":[{...,"playlist_items":[...]}]}}`.
  /// Returns an empty list when the station has no items, and `null` when the
  /// body is malformed (so the caller keeps the last known list rather than
  /// dropping playback). When [stationSlug] is given the matching station is
  /// preferred; otherwise the first station is used.
  ///
  /// Static + pure so it can be unit-tested without the network.
  static List<PlaylistItem>? parsePlaylistResponse(
    String body, {
    String? stationSlug,
  }) {
    try {
      final decoded = json.decode(body);
      if (decoded is! Map) return null;
      final data = decoded['data'];
      if (data is! Map) return null;
      final stations = data['stations'];
      if (stations is! List) return null;
      if (stations.isEmpty) return const [];

      Map? station;
      if (stationSlug != null) {
        for (final s in stations) {
          if (s is Map && s['slug'] == stationSlug) {
            station = s;
            break;
          }
        }
      }
      station ??= stations.first is Map ? stations.first as Map : null;
      if (station == null) return null;

      final rawItems = station['playlist_items'];
      if (rawItems is! List) return const [];
      final items = <PlaylistItem>[];
      for (final raw in rawItems) {
        if (raw is Map<String, dynamic>) {
          items.add(PlaylistItem.fromJson(raw));
        } else if (raw is Map) {
          items.add(PlaylistItem.fromJson(Map<String, dynamic>.from(raw)));
        }
      }
      items.sort((a, b) => a.order.compareTo(b.order));
      return items;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    stopSync();
    _updates.close();
    _client.close();
  }

  void _log(String message) => debugPrint('PlaylistSyncService: $message');
}
