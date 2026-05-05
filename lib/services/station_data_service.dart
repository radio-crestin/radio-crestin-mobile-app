import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:radio_crestin/constants.dart';
import 'package:radio_crestin/performance_monitor.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_sort_service.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/services/image_cache_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/utils/api_utils.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Why a metadata sync was requested. Drives the choice between full refresh,
/// audio-aligned offset diff, and live-timeline diff. Listed in priority
/// order — when multiple reasons coalesce while a sync is in flight, the
/// lower index (= higher priority) wins.
enum SyncReason {
  /// Initial bootstrap on app start.
  startup,

  /// App returned from background — distrust everything, refetch.
  appResumed,

  /// User picked a station to play.
  stationPlayed,

  /// User changed the "încărcare în avans" pre-buffer setting.
  seekOffsetChanged,

  /// HLS DATERANGE flipped, ICY tag changed, or ID3 metadata fired —
  /// the audio just told us a new song is playing.
  audioMetadataChanged,

  /// 60s wall-clock tick — keep the visible station list reasonably fresh.
  periodic,
}

class StationDataService {
  final GraphQLClient graphqlClient;

  // ---------------------------------------------------------------------------
  // Sync engine state
  // ---------------------------------------------------------------------------

  /// Fixed cadence for the periodic safety-net poll. Audio events drive
  /// the playing station's now-playing; this tick keeps the list itself
  /// fresh for stations the user can see but isn't playing.
  static const _periodicInterval = Duration(seconds: 60);

  /// 10-min full refresh window. Inserted into the next sync (regardless
  /// of reason) once elapsed, to pull GraphQL stations + reviews drift.
  static const _fullRefreshInterval = Duration(minutes: 10);

  /// If the audio metadata channel hasn't said anything in this long, the
  /// next periodic tick adds an offset fetch as a safety net so the
  /// player UI doesn't sit on a stale audio-aligned now_playing.
  static const _audioEventSafetyNet = Duration(minutes: 5);

  /// Settle delay between detecting an audio metadata change locally
  /// (HLS DATERANGE / ICY tag) and querying the backend. Gives the
  /// `/stations-metadata` ingestion path a moment to pick up the new
  /// song before we ask for it; without this we sometimes diff against
  /// stale data and have to refetch on the next tick.
  static const _audioEventSettleDelay = Duration(seconds: 2);

  /// Maximum gap (seconds) between consecutive offset-fetch timestamps
  /// before the differential is dropped and a full payload is requested.
  /// Guards against stale cursors after long pauses, app backgrounding, or
  /// shifts between the synthetic offset and the precise PROGRAM-DATE-TIME.
  static const int _maxOffsetDiffGapSeconds = 60;

  Timer? _periodicTimer;

  /// Mutex over the sync pipeline. All paths funnel through `enqueueSync`,
  /// so a single in-flight call is enough — overlapping triggers coalesce
  /// into [_pendingReason].
  bool _isSyncing = false;

  /// Highest-priority reason queued while a sync is in flight. Drained on
  /// completion of the current sync. `null` means nothing pending.
  SyncReason? _pendingReason;

  /// Live-timeline cursor (Unix seconds, 10s-rounded). Sent as
  /// `changes_from_timestamp` on the next live diff.
  int _lastFetchTimestamp = 0;

  /// Offset-timeline cursor (Unix seconds, 10s-rounded). Stored as the
  /// value sent on the request, not wall-clock now, so it matches the
  /// server's cache key. Reset to 0 whenever the offset frame may have
  /// shifted (full refresh, error recovery, init).
  int _lastOffsetFetchTimestamp = 0;

  /// When the last full refresh (GraphQL + REST) was performed.
  DateTime? _lastFullRefreshTime;

  /// Last time the audio layer reported a metadata change (DATERANGE
  /// flip, ICY tag, ID3). Used by the periodic safety net.
  DateTime? _lastAudioEventTime;

  // ---------------------------------------------------------------------------
  // Audio sync hooks (set by AppAudioHandler after init)
  // ---------------------------------------------------------------------------

  /// Returns the actual stream type ('HLS', 'direct_stream', etc.) if the
  /// given station ID is currently playing, or null if it's not the
  /// active station.
  String? Function(int stationId)? getPlayingStreamType;

  /// Returns the actual offset from the live edge for the currently
  /// playing HLS stream, derived from `player.duration - player.position`.
  /// Returns null if not playing HLS or if duration/position is unavailable.
  Duration? Function()? getActualPlaybackOffset;

  /// Returns the precise Unix timestamp (10s-aligned) of the audio
  /// currently being played, derived from EXT-X-PROGRAM-DATE-TIME +
  /// player.position. Returns null when not playing HLS or when the
  /// playlist hasn't been parsed yet.
  int? Function()? getHlsPlaybackTimestamp;

  /// Returns true when HLS is the active stream type.
  bool Function()? isPlayingHls;

  // ---------------------------------------------------------------------------
  // Streams
  // ---------------------------------------------------------------------------

  final BehaviorSubject<List<Station>> stations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<Station>> filteredStations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<String>> favoriteStationSlugs = BehaviorSubject.seeded([]);
  final BehaviorSubject<List<Query$GetStations$station_groups>> stationGroups =
      BehaviorSubject.seeded(<Query$GetStations$station_groups>[]);
  final BehaviorSubject<Query$GetStations$station_groups?> selectedStationGroup =
      BehaviorSubject.seeded(null);

  /// When true, next/previous navigation cycles through favorites first,
  /// then falls through to the full sorted list.
  bool startedFromFavorites = false;

  /// Cached sort order (list of slugs). Keeps the station order stable
  /// during the session. Only invalidated on manual refresh or sort change.
  List<String>? _cachedSortOrder;
  StationSortOption? _cachedSortOption;
  int _cachedStationCount = 0;

  /// Emits whenever the sort cache is invalidated, so listeners (CarPlay,
  /// Android Auto) can rebuild their station lists with the new order.
  final PublishSubject<void> sortOrderChanged = PublishSubject<void>();

  // Constants
  static const _favoriteStationsKey = 'favoriteStationSlugs';
  static const _cachedStationsKey = 'cached_stations_data';
  static const _minStationsForCache = 10;
  static const _fieldTypenames = {
    'stations': 'StationType',
    'station_streams': 'StationStreamType',
    'posts': 'PostType',
    'uptime': 'StationUptimeType',
    'now_playing': 'StationNowPlayingType',
    'song': 'SongType',
    'artist': 'ArtistType',
    'reviews': 'ReviewType',
    'station_groups': 'StationGroupType',
    'station_to_station_groups': 'StationToStationGroupType',
  };

  StationDataService({required this.graphqlClient});

  void _log(String message) {
    debugPrint("StationDataService: $message");
  }

  // ---------------------------------------------------------------------------
  // Public API — every refresh path funnels through enqueueSync.
  // ---------------------------------------------------------------------------

  Future<void> initialize() async {
    _initFilteredStationsStream();
    await _initFavoriteStationSlugs();
    await _bootstrap();
  }

  /// Single entry point for every refresh. Coalesces overlapping triggers
  /// and runs them in priority order so concurrent callers can fire and
  /// forget.
  Future<void> enqueueSync(SyncReason reason) async {
    if (_isSyncing) {
      // Coalesce into the pending slot if this reason is higher priority
      // (lower enum index) than what's already queued.
      if (_pendingReason == null || reason.index < _pendingReason!.index) {
        _pendingReason = reason;
        _log("queue: $reason (pending after current sync)");
      }
      return;
    }
    _isSyncing = true;
    try {
      var current = reason;
      while (true) {
        await _executeSync(current);
        final next = _pendingReason;
        if (next == null) break;
        _pendingReason = null;
        current = next;
      }
    } finally {
      _isSyncing = false;
    }
  }

  /// Convenience wrappers — keep call sites readable.
  Future<void> refreshStations() => enqueueSync(SyncReason.seekOffsetChanged);
  Future<void> refreshMetadataNow() => enqueueSync(SyncReason.audioMetadataChanged);

  /// Called when the app resumes from background.
  Future<void> onAppResumed() async {
    _log("App resumed from background");
    resumePeriodic();
    await enqueueSync(SyncReason.appResumed);
  }

  /// Called by AppAudioHandler when a new station starts playing.
  Future<void> onStationPlayed() => enqueueSync(SyncReason.stationPlayed);

  void pausePeriodic() {
    _log("Pausing periodic sync");
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  void resumePeriodic() {
    if (_periodicTimer != null) return;
    _log("Resuming periodic sync (every ${_periodicInterval.inSeconds}s)");
    _periodicTimer = Timer.periodic(
      _periodicInterval,
      (_) => enqueueSync(SyncReason.periodic),
    );
  }

  void dispose() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  // Backward-compatible aliases — older call sites used these names.
  void pausePolling() => pausePeriodic();
  void resumePolling() => resumePeriodic();

  // ---------------------------------------------------------------------------
  // Sync engine internals
  // ---------------------------------------------------------------------------

  /// One sync iteration. Promotes any reason to a full refresh when the
  /// 10-min window has elapsed; otherwise dispatches by reason kind.
  Future<void> _executeSync(SyncReason reason) async {
    final fullDue = _lastFullRefreshTime == null ||
        DateTime.now().difference(_lastFullRefreshTime!) >= _fullRefreshInterval;

    final isFullReason = reason == SyncReason.startup ||
        reason == SyncReason.appResumed ||
        reason == SyncReason.stationPlayed ||
        reason == SyncReason.seekOffsetChanged;

    if (isFullReason || fullDue) {
      await _doFullRefresh(reason, becausePromoted: !isFullReason);
      return;
    }
    if (reason == SyncReason.audioMetadataChanged) {
      await _doAudioDiff();
      return;
    }
    await _doPeriodicDiff();
  }

  /// Full refresh: GraphQL stations + live metadata, merged in one shot.
  /// Resets the offset cursor — the next audio event will repopulate it.
  Future<void> _doFullRefresh(SyncReason reason, {required bool becausePromoted}) async {
    _log("full refresh: $reason${becausePromoted ? ' (promoted: 10-min window)' : ''}");
    invalidateSortCache();
    try {
      await _fetchStationsWithMetadata();
      _lastFullRefreshTime = DateTime.now();
      _lastFetchTimestamp = getRoundedTimestamp();
      _lastOffsetFetchTimestamp = 0;
      _preCacheStationThumbnails();
    } catch (e) {
      _log("full refresh failed: $e");
    }
  }

  /// Audio-event diff: fetch metadata at the audio's timestamp so the
  /// playing station's now_playing matches what the user actually hears.
  /// Single request — no live fetch, no parallelism.
  Future<void> _doAudioDiff() async {
    if (stations.value.isEmpty) return;
    _lastAudioEventTime = DateTime.now();

    // Brief settle so the backend ingestion has caught up with the
    // song change the audio just announced. Coalesced ID3/DATERANGE
    // bursts pay this once because the mutex holds the whole window.
    _log("audio diff: settling ${_audioEventSettleDelay.inSeconds}s before fetch");
    await Future.delayed(_audioEventSettleDelay);

    final hlsActive = isPlayingHls?.call() ?? false;
    final hlsTimestamp = getHlsPlaybackTimestamp?.call();
    final int audioTs;
    if (hlsTimestamp != null) {
      audioTs = hlsTimestamp;
    } else if (hlsActive) {
      final actualOffset = getActualPlaybackOffset?.call();
      final configuredOffset = SeekModeManager.currentOffset;
      audioTs = getRoundedTimestamp(offset: actualOffset ?? configuredOffset);
    } else {
      // Direct/MP3 stream — audio is "live", so use wall-clock.
      audioTs = getRoundedTimestamp();
    }

    final canDiff = _lastOffsetFetchTimestamp > 0 &&
        audioTs > _lastOffsetFetchTimestamp &&
        (audioTs - _lastOffsetFetchTimestamp) <= _maxOffsetDiffGapSeconds;

    final result = await _fetchMetadata(
      audioTs,
      changesFromTimestamp: canDiff ? _lastOffsetFetchTimestamp : null,
    );
    _lastOffsetFetchTimestamp = audioTs;
    if (result == null || result.isEmpty) return;

    _applyMerge(liveMetadata: null, offsetMetadata: result);
  }

  /// 60s safety-net diff: refreshes the visible station list at the live
  /// timeline. When audio events have gone quiet for [_audioEventSafetyNet],
  /// also includes an offset fetch so the player UI doesn't sit stale.
  Future<void> _doPeriodicDiff() async {
    if (stations.value.isEmpty) return;

    final liveTs = getRoundedTimestamp();
    final hlsActive = isPlayingHls?.call() ?? false;
    final audioStale = _lastAudioEventTime == null ||
        DateTime.now().difference(_lastAudioEventTime!) > _audioEventSafetyNet;
    final wantOffsetSafetyNet = hlsActive && audioStale;

    int offsetTs = liveTs;
    if (wantOffsetSafetyNet) {
      final hlsTimestamp = getHlsPlaybackTimestamp?.call();
      offsetTs = hlsTimestamp ??
          getRoundedTimestamp(
            offset: getActualPlaybackOffset?.call() ?? SeekModeManager.currentOffset,
          );
    }
    final fetchOffset = wantOffsetSafetyNet && offsetTs != liveTs;

    final canDiffLive = _lastFetchTimestamp > 0;
    final canDiffOffset = fetchOffset &&
        _lastOffsetFetchTimestamp > 0 &&
        offsetTs > _lastOffsetFetchTimestamp &&
        (offsetTs - _lastOffsetFetchTimestamp) <= _maxOffsetDiffGapSeconds;

    PerformanceMonitor.startOperation('periodic_sync');
    Map<int, Map<String, dynamic>>? liveMeta;
    Map<int, Map<String, dynamic>>? offsetMeta;
    if (fetchOffset) {
      final results = await Future.wait([
        _fetchMetadata(liveTs, changesFromTimestamp: canDiffLive ? _lastFetchTimestamp : null),
        _fetchMetadata(offsetTs, changesFromTimestamp: canDiffOffset ? _lastOffsetFetchTimestamp : null),
      ]);
      liveMeta = results[0];
      offsetMeta = results[1];
    } else {
      liveMeta = await _fetchMetadata(
        liveTs,
        changesFromTimestamp: canDiffLive ? _lastFetchTimestamp : null,
      );
    }
    PerformanceMonitor.endOperation('periodic_sync');

    _lastFetchTimestamp = liveTs;
    if (fetchOffset) _lastOffsetFetchTimestamp = offsetTs;

    if (liveMeta == null && offsetMeta == null) {
      _log("periodic: both fetches failed, skipping");
      return;
    }
    _applyMerge(liveMetadata: liveMeta, offsetMetadata: offsetMeta);
  }

  /// Merges fetched metadata into the in-memory station list. Either map
  /// may be null when only one source was fetched. Per-station, picks the
  /// HLS-aligned (offset) source for the playing station and the live
  /// source for everyone else, then publishes to the [stations] stream
  /// only if a user-visible field actually changed.
  void _applyMerge({
    required Map<int, Map<String, dynamic>>? liveMetadata,
    required Map<int, Map<String, dynamic>>? offsetMetadata,
  }) {
    if (liveMetadata == null && offsetMetadata == null) return;

    final currentStations = stations.value;
    final updatedStations = currentStations.map((station) {
      final useOffset = _shouldUseOffsetMetadata(station);
      final primarySource = useOffset ? offsetMetadata : liveMetadata;
      final fallbackSource = useOffset ? liveMetadata : offsetMetadata;
      final metadata = primarySource?[station.id] ?? fallbackSource?[station.id];
      if (metadata == null) return station;
      final liveNowPlaying = liveMetadata?[station.id]?['now_playing'];
      final liveListeners = liveNowPlaying is Map<String, dynamic>
          ? liveNowPlaying['listeners'] as int?
          : null;
      return _mergeStationWithMetadata(station, metadata, liveListeners: liveListeners);
    }).toList();

    if (_hasStationsChanged(currentStations, updatedStations)) {
      stations.add(updatedStations);
      _log("merge: stations updated");
      if (SeekModeManager.isUnstableConnection) {
        _preCacheSongThumbnails(updatedStations);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Favorites
  // ---------------------------------------------------------------------------

  Future<void> setStationIsFavorite(Station station, bool isFavorite) async {
    _log("setStationIsFavorite: ${station.slug} $isFavorite");
    if (isFavorite) {
      favoriteStationSlugs.add([...favoriteStationSlugs.value, station.slug]);
    } else {
      favoriteStationSlugs
          .add(favoriteStationSlugs.value.where((slug) => slug != station.slug).toList());
    }
    final SharedPreferences prefs = GetIt.instance<SharedPreferences>();
    await prefs.setString(_favoriteStationsKey, json.encode(favoriteStationSlugs.value));
  }

  Future<void> _initFavoriteStationSlugs() async {
    final SharedPreferences prefs = GetIt.instance<SharedPreferences>();
    final String? favoriteJson = prefs.getString(_favoriteStationsKey);
    if (favoriteJson != null) {
      favoriteStationSlugs.add(List<String>.from(json.decode(favoriteJson)));
    }
  }

  // ---------------------------------------------------------------------------
  // Initial data loading
  // ---------------------------------------------------------------------------

  Future<void> _bootstrap() async {
    _log("bootstrap: loading cached/fallback stations");
    final cached = await _loadCachedStations();
    final hasCachedData = cached != null;
    if (hasCachedData) {
      _log("bootstrap: ${cached.stations.length} stations from cache");
      _applyStationsData(cached);
    } else {
      final fallback = await _loadFallbackStations();
      if (fallback != null) {
        _log("bootstrap: ${fallback.stations.length} stations from bundled fallback");
        _applyStationsData(fallback);
      }
    }

    // Start the periodic timer + kick off a startup sync. With cached
    // data we don't await, so the UI lights up immediately and the
    // network refresh fills in over the next second or two. Without
    // cache we have to wait — there's nothing to render yet.
    resumePeriodic();
    if (hasCachedData) {
      unawaited(enqueueSync(SyncReason.startup));
    } else {
      PerformanceMonitor.startOperation('initial_stations_fetch');
      await enqueueSync(SyncReason.startup);
      PerformanceMonitor.endOperation('initial_stations_fetch');
    }
  }

  Future<Query$GetStations?> _loadCachedStations() async {
    try {
      final SharedPreferences prefs = GetIt.instance<SharedPreferences>();
      final cachedJson = prefs.getString(_cachedStationsKey);
      if (cachedJson == null) return null;
      final data = json.decode(cachedJson) as Map<String, dynamic>;
      _injectTypenames(data);
      final parsed = Query$GetStations.fromJson(data);
      if (parsed.stations.length < _minStationsForCache) return null;
      return parsed;
    } catch (e) {
      _log("Error loading cached stations: $e");
      return null;
    }
  }

  Future<void> _cacheStationsData(Query$GetStations data) async {
    try {
      final SharedPreferences prefs = GetIt.instance<SharedPreferences>();
      final dataJson = data.toJson();
      final stationsList = dataJson['stations'] as List?;
      if (stationsList != null) {
        for (final station in stationsList) {
          if (station is Map<String, dynamic>) {
            station['total_listeners'] = null;
          }
        }
      }
      await prefs.setString(_cachedStationsKey, json.encode(dataJson));
      _log("Cached ${data.stations.length} stations to prefs");
    } catch (e) {
      _log("Error caching stations: $e");
    }
  }

  Future<Query$GetStations?> _loadFallbackStations() async {
    try {
      _log("Loading fallback stations from asset");
      final jsonString = await rootBundle.loadString('assets/fallback-stations.json');
      final data = (json.decode(jsonString) as Map<String, dynamic>)['data']
          as Map<String, dynamic>;
      _injectTypenames(data);
      return Query$GetStations.fromJson(data);
    } catch (e) {
      _log("Error loading fallback stations: $e");
      return null;
    }
  }

  /// Creates a Station with reviews_stats from the REST cache.
  Station _createStation(Query$GetStations$stations raw) {
    final stats = reviewsStatsCache[raw.id];
    return Station(
      rawStationData: raw,
      averageRating: stats?.averageRating ?? 0,
      numberOfReviews: stats?.numberOfReviews ?? 0,
    );
  }

  void _applyStationsData(Query$GetStations data) {
    stations.add(data.stations.map(_createStation).toList());
    stationGroups.add(data.station_groups);
  }

  /// Fetches stations + live metadata, merges, applies in a single UI
  /// update. Used by full-refresh paths only — periodic and audio-event
  /// paths skip the heavy GraphQL hop.
  Future<void> _fetchStationsWithMetadata() async {
    final liveTs = getRoundedTimestamp();
    final futures = <Future>[
      graphqlClient.query(
        Options$Query$GetStations(fetchPolicy: FetchPolicy.networkOnly),
      ),
      _fetchMetadata(liveTs),
    ];
    final results = await Future.wait(futures);
    final stationsResult = results[0] as QueryResult<Query$GetStations>;
    final liveMetadata = results[1] as Map<int, Map<String, dynamic>>?;

    final parsedData = stationsResult.parsedData;
    if (parsedData != null && parsedData.stations.length >= _minStationsForCache) {
      final stationsWithMetadata = parsedData.stations.map((r) {
        var station = _createStation(r);
        final metadata = liveMetadata?[station.id];
        if (metadata != null) {
          final liveNowPlaying = metadata['now_playing'];
          final liveListeners = liveNowPlaying is Map<String, dynamic>
              ? liveNowPlaying['listeners'] as int?
              : null;
          station = _mergeStationWithMetadata(station, metadata, liveListeners: liveListeners);
        }
        return station;
      }).toList();

      stations.add(stationsWithMetadata);
      stationGroups.add(parsedData.station_groups);
      _cacheStationsData(parsedData);
    }
  }

  // ---------------------------------------------------------------------------
  // REST metadata fetch
  // ---------------------------------------------------------------------------

  /// Fetches metadata from REST API.
  /// When [changesFromTimestamp] is provided, only returns stations that
  /// changed since that timestamp (differential update, like the
  /// radiocrestin.ro web app).
  Future<Map<int, Map<String, dynamic>>?> _fetchMetadata(
    int timestamp, {
    int? changesFromTimestamp,
  }) async {
    var url = '${CONSTANTS.STATIONS_METADATA_URL}?timestamp=$timestamp';
    if (changesFromTimestamp != null && changesFromTimestamp > 0) {
      url += '&changes_from_timestamp=$changesFromTimestamp';
    }
    final isDiff = changesFromTimestamp != null && changesFromTimestamp > 0;
    final mode = isDiff ? 'diff' : 'full';
    final stopwatch = Stopwatch()..start();
    _log("→ metadata fetch [$mode] ts=$timestamp"
        "${isDiff ? ' from=$changesFromTimestamp' : ''}");
    try {
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      stopwatch.stop();
      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body) as Map<String, dynamic>;
        final stationsMetadata = (jsonData['data']?['stations_metadata'] as List?) ?? [];
        final map = <int, Map<String, dynamic>>{};
        for (final item in stationsMetadata) {
          if (item is Map<String, dynamic> && item['id'] != null) {
            map[item['id'] as int] = item;
          }
        }
        _log("✓ metadata fetch [$mode] ts=$timestamp "
            "→ ${map.length} stations in ${stopwatch.elapsedMilliseconds}ms");
        return map;
      } else {
        _log("✗ metadata fetch [$mode] ts=$timestamp "
            "→ HTTP ${response.statusCode} in ${stopwatch.elapsedMilliseconds}ms");
        return null;
      }
    } catch (e) {
      stopwatch.stop();
      _log("✗ metadata fetch [$mode] ts=$timestamp "
          "→ error in ${stopwatch.elapsedMilliseconds}ms: $e");
      return null;
    }
  }

  /// Merges lightweight metadata (uptime, now_playing, listeners) into an
  /// existing station. Preserves all other fields (station_streams,
  /// posts, reviews, etc.).
  Station _mergeStationWithMetadata(Station station, Map<String, dynamic> metadata, {int? liveListeners}) {
    final stationJson = station.rawStationData.toJson();

    final metadataUptime = metadata['uptime'];
    if (metadataUptime is Map<String, dynamic>) {
      stationJson['uptime'] = {
        '__typename': 'StationUptimeType',
        'is_up': metadataUptime['is_up'],
        'latency_ms': metadataUptime['latency_ms'],
        'timestamp': metadataUptime['timestamp'],
      };
    }

    final metadataNowPlaying = metadata['now_playing'];
    if (metadataNowPlaying is Map<String, dynamic>) {
      stationJson['total_listeners'] = liveListeners ?? metadataNowPlaying['listeners'];

      final metadataSong = metadataNowPlaying['song'];
      Map<String, dynamic>? songJson;
      if (metadataSong is Map<String, dynamic>) {
        final metadataArtist = metadataSong['artist'];
        songJson = {
          '__typename': 'SongType',
          'id': metadataSong['id'],
          'name': metadataSong['name'],
          'thumbnail_url': metadataSong['thumbnail_url'],
          'artist': metadataArtist is Map<String, dynamic>
              ? {
                  '__typename': 'ArtistType',
                  'id': metadataArtist['id'],
                  'name': metadataArtist['name'],
                  'thumbnail_url': metadataArtist['thumbnail_url'],
                }
              : null,
        };
      }

      // Metadata API doesn't include now_playing.id; reuse previous value or default to 0
      stationJson['now_playing'] = {
        '__typename': 'StationNowPlayingType',
        'id': station.rawStationData.now_playing?.id ?? 0,
        'timestamp': metadataNowPlaying['timestamp'],
        'song': songJson,
      };
    }

    final stats = reviewsStatsCache[station.id];
    return Station(
      rawStationData: Query$GetStations$stations.fromJson(stationJson),
      averageRating: stats?.averageRating ?? station.averageRating,
      numberOfReviews: stats?.numberOfReviews ?? station.reviewCount,
    );
  }

  // ---------------------------------------------------------------------------
  // Station ordering & navigation (single source of truth)
  // ---------------------------------------------------------------------------

  /// Returns stations sorted by the user's saved sort preference.
  /// This is THE single source of truth for station order across
  /// phone, CarPlay, and Android Auto.
  ///
  /// The sort order is cached so it stays stable during the session.
  /// It only re-sorts on manual refresh, sort option change, or when
  /// the station set changes (new/removed stations).
  List<Station> getSortedStations() {
    final allStations = filteredStations.value;
    if (allStations.isEmpty) return allStations;
    final sortOption = StationSortService.loadSavedSort();

    // Check if the cached order is still valid
    final cacheValid = _cachedSortOrder != null &&
        _cachedSortOption == sortOption &&
        _cachedStationCount == allStations.length;

    if (cacheValid) {
      // Reorder current stations by the cached slug order, preserving
      // fresh metadata (listeners, now_playing, etc.)
      final stationMap = {for (final s in allStations) s.slug: s};
      final result = <Station>[];
      for (final slug in _cachedSortOrder!) {
        final station = stationMap.remove(slug);
        if (station != null) result.add(station);
      }
      // Append any new stations not in the cache (e.g. added since last sort)
      result.addAll(stationMap.values);
      return result;
    }

    // Cache miss — compute fresh sort
    // Refresh play counts from disk so the Android Auto engine (separate isolate)
    // sees counts written by the phone engine during the current session.
    final playCountService = GetIt.instance.isRegistered<PlayCountService>()
        ? GetIt.instance<PlayCountService>()
        : null;
    playCountService?.refresh();
    final playCounts = playCountService?.playCounts ?? <String, int>{};
    final favSlugs = favoriteStationSlugs.value;
    final sorted = StationSortService.sort(
      stations: allStations,
      sortBy: sortOption,
      playCounts: playCounts,
      favoriteSlugs: favSlugs,
    ).sorted;

    // Cache the order
    _cachedSortOrder = sorted.map<String>((s) => s.slug).toList();
    _cachedSortOption = sortOption;
    _cachedStationCount = allStations.length;

    return sorted;
  }

  /// Invalidates the cached sort order, forcing a re-sort on the next call
  /// to [getSortedStations]. Call this on manual refresh or sort option change.
  void invalidateSortCache() {
    _cachedSortOrder = null;
    _cachedSortOption = null;
    _cachedStationCount = 0;
    sortOrderChanged.add(null);
  }

  /// Builds the navigation playlist: if the user started from favorites,
  /// favorites come first (in sorted order), then the remaining stations.
  /// Otherwise, returns the full sorted list.
  List<Station> _getNavigationPlaylist() {
    final sorted = getSortedStations();
    if (!startedFromFavorites) return sorted;

    final favSlugs = favoriteStationSlugs.value;
    if (favSlugs.isEmpty) return sorted;

    final favorites = sorted.where((s) => favSlugs.contains(s.slug)).toList();
    final others = sorted.where((s) => !favSlugs.contains(s.slug)).toList();
    return [...favorites, ...others];
  }

  /// Returns the next station in the navigation playlist after [currentSlug].
  /// Wraps around to the first station at the end.
  Station? getNextStation(String currentSlug) {
    final playlist = _getNavigationPlaylist();
    if (playlist.isEmpty) return null;
    final idx = playlist.indexWhere((s) => s.slug == currentSlug);
    if (idx < 0) return playlist.first;
    return playlist[(idx + 1) % playlist.length];
  }

  /// Returns the previous station in the navigation playlist before [currentSlug].
  /// Wraps around to the last station at the beginning.
  Station? getPreviousStation(String currentSlug) {
    final playlist = _getNavigationPlaylist();
    if (playlist.isEmpty) return null;
    final idx = playlist.indexWhere((s) => s.slug == currentSlug);
    if (idx <= 0) return playlist.last;
    return playlist[idx - 1];
  }

  // ---------------------------------------------------------------------------
  // Filtering
  // ---------------------------------------------------------------------------

  void _initFilteredStationsStream() {
    Rx.combineLatest2<Query$GetStations$station_groups?, List<Station>, List<Station>>(
      selectedStationGroup.stream,
      stations.stream,
      (selectedGroup, allStations) {
        allStations.sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
        if (selectedGroup == null) return allStations;
        selectedGroup.station_to_station_groups
            .sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
        final selectedStationsIds =
            selectedGroup.station_to_station_groups.map((e) => e.station_id);
        return allStations.where((s) => selectedStationsIds.contains(s.id)).toList();
      },
    ).listen((filtered) => filteredStations.add(filtered));
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  bool _hasStationsChanged(List<Station> oldStations, List<Station> newStations) {
    if (oldStations.length != newStations.length) return true;
    for (int i = 0; i < oldStations.length; i++) {
      final o = oldStations[i];
      final n = newStations[i];
      if (o.id != n.id ||
          o.title != n.title ||
          o.songId != n.songId ||
          o.songTitle != n.songTitle ||
          o.totalListeners != n.totalListeners ||
          o.isUp != n.isUp) {
        return true;
      }
    }
    return false;
  }

  /// For the currently playing station, check the actual stream type in use.
  /// For all other stations, fall back to the configured primary stream type.
  bool _shouldUseOffsetMetadata(Station station) {
    final playingType = getPlayingStreamType?.call(station.id);
    if (playingType != null) return playingType == 'HLS';
    return _isStationHls(station);
  }

  bool _isStationHls(Station station) {
    final List<Query$GetStations$stations$station_streams>? streams = station.stationStreams;
    if (streams == null || streams.isEmpty) return false;
    final primary = streams.reduce((a, b) => a.order <= b.order ? a : b);
    return primary.type == 'HLS';
  }

  void _injectTypenames(Map<String, dynamic> data, [String typename = 'queryRoot']) {
    data['__typename'] = typename;
    for (final entry in data.entries) {
      final childType = _fieldTypenames[entry.key];
      if (childType == null) continue;
      if (entry.value is List) {
        for (final item in entry.value) {
          if (item is Map<String, dynamic>) _injectTypenames(item, childType);
        }
      } else if (entry.value is Map<String, dynamic>) {
        _injectTypenames(entry.value, childType);
      }
    }
  }

  void _preCacheStationThumbnails() {
    if (NetworkService.instance.isOnMobileData.value) return;
    final urls = stations.value
        .where((s) => s.thumbnailUrl != null && s.thumbnailUrl!.isNotEmpty)
        .map((s) => s.thumbnailUrl!)
        .toList();
    if (urls.isEmpty) return;
    ImageCacheService.instance.preCacheUrls(urls);
  }

  /// In unstable connection mode, pre-cache all song thumbnails permanently to disk.
  void _preCacheSongThumbnails(List<Station> stationsList) {
    final urls = stationsList
        .where((s) => s.rawStationData.now_playing?.song?.thumbnail_url != null)
        .map((s) => s.rawStationData.now_playing!.song!.thumbnail_url!)
        .where((url) => url.isNotEmpty)
        .toSet() // deduplicate
        .toList();
    if (urls.isEmpty) return;
    _log("Pre-caching ${urls.length} song thumbnails (unstable mode)");
    ImageCacheService.instance.preCacheUrls(urls);
  }
}
