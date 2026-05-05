import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

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

class StationDataService {
  final GraphQLClient graphqlClient;

  // Polling state
  Timer? _pollTimer;
  bool _isPolling = false;
  bool _isPollInFlight = false;
  static const _pollInterval = Duration(seconds: 10);
  static const _fullRefreshInterval = Duration(minutes: 10);

  /// Timestamp (Unix seconds, rounded to 10s) of the last successful metadata fetch.
  /// Used as `changes_from_timestamp` to only receive changed stations.
  int _lastFetchTimestamp = 0;

  /// Timestamp (Unix seconds, rounded to 10s) of the last successful **offset**
  /// metadata fetch — i.e. the value sent on the request, not wall-clock now.
  /// The server's cache key is keyed off the request value, so the cursor must
  /// be too. Reset to 0 whenever the offset frame of reference may have shifted
  /// (full refresh, error recovery, init).
  int _lastOffsetFetchTimestamp = 0;

  /// Maximum gap (seconds) between consecutive offset-fetch timestamps before
  /// the differential is dropped and a full fetch is issued. Protects against
  /// stale cursors after long pauses, app backgrounding, or shifts between
  /// the synthetic offset and the precise PROGRAM-DATE-TIME source.
  static const int _maxOffsetDiffGapSeconds = 60;

  /// When the last full refresh (GraphQL + REST) was performed.
  DateTime? _lastFullRefreshTime;

  /// Returns the actual stream type ('HLS', 'direct_stream', etc.) if the given
  /// station ID is currently playing, or null if it's not the active station.
  /// Set by AppAudioHandler after init to avoid circular dependency.
  String? Function(int stationId)? getPlayingStreamType;

  /// Returns the actual offset from the live edge for the currently playing
  /// HLS stream, derived from `player.duration - player.position`.
  /// Returns null if not playing HLS or if duration/position is unavailable.
  /// Set by AppAudioHandler after init to avoid circular dependency.
  Duration? Function()? getActualPlaybackOffset;

  /// Returns the precise Unix timestamp (10s-aligned) of the audio currently
  /// being played, derived from EXT-X-PROGRAM-DATE-TIME + player.position.
  /// This is the most accurate source for metadata sync — preferred over
  /// the offset-based approach. Returns null when not playing HLS or when
  /// the playlist hasn't been parsed yet.
  /// Set by AppAudioHandler after init to avoid circular dependency.
  int? Function()? getHlsPlaybackTimestamp;

  /// Returns true when HLS is the active stream type. Used to decide whether
  /// an offset timestamp is needed — non-HLS streams play live so their
  /// metadata should always use the live timestamp.
  /// Set by AppAudioHandler after init to avoid circular dependency.
  bool Function()? isPlayingHls;

  // Streams
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
    developer.log("StationDataService: $message");
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Future<void> initialize() async {
    _initFilteredStationsStream();
    await _initFavoriteStationSlugs();
    _setupRefreshStations();
  }

  /// Full refresh: re-fetches stations from GraphQL + metadata from REST.
  /// Called on init, every 30 minutes, and on app resume from background.
  Future<void> refreshStations() async {
    _log("Full refresh triggered");
    invalidateSortCache();
    await _fetchStationsWithMetadata();
    _lastFullRefreshTime = DateTime.now();
    _lastFetchTimestamp = getRoundedTimestamp();
    _lastOffsetFetchTimestamp = 0;
    _preCacheStationThumbnails();
  }

  /// Force an out-of-cycle lightweight metadata poll. Used when something
  /// has just changed (DATERANGE flipped, app foregrounded) and we don't
  /// want to wait up to the next scheduled tick. Cheaper than
  /// `refreshStations` — skips the heavy GraphQL station-list reload and
  /// only refreshes `now_playing` + listener counts. Safe to call while a
  /// poll is already in flight (`_pollMetadata` has an `_isPollInFlight`
  /// guard, so a near-simultaneous call is a no-op).
  Future<void> refreshMetadataNow() async => _pollMetadata();

  /// Called when app resumes from background.
  /// Forces a full refresh to pick up any changes while backgrounded.
  Future<void> onAppResumed() async {
    _log("App resumed from background, triggering full refresh");
    await refreshStations();
    resumePolling();
  }

  void pausePolling() {
    _log("Pausing station polling");
    _pollTimer?.cancel();
    _pollTimer = null;
    _isPolling = false;
  }

  void resumePolling() {
    if (!_isPolling) {
      _log("Resuming station polling");
      _isPolling = true;
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(_pollInterval, (_) => _pollMetadata());
    }
  }

  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isPolling = false;
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

  void _setupRefreshStations() async {
    _log("Starting to fetch stations");

    // Phase 1: Load cached data from previous session, or bundled fallback
    final cached = await _loadCachedStations();
    final hasCachedData = cached != null;
    if (hasCachedData) {
      _log("Loaded ${cached.stations.length} stations from cache");
      _applyStationsData(cached);
    } else {
      final fallback = await _loadFallbackStations();
      if (fallback != null) {
        _log("Loaded ${fallback.stations.length} stations from bundled fallback");
        _applyStationsData(fallback);
      }
    }

    // Phase 2: Fetch stations + metadata from network.
    // If we have cached data, don't block — fetch in background for faster startup.
    // If no cache, we must await to get initial data.
    if (hasCachedData) {
      // Non-blocking: start network fetch and polling immediately
      _lastFullRefreshTime = DateTime.now();
      _lastFetchTimestamp = getRoundedTimestamp();
      _lastOffsetFetchTimestamp = 0;
      _isPolling = true;
      _pollTimer = Timer.periodic(_pollInterval, (_) => _pollMetadata());

      // Background refresh — updates UI when ready, no-op if offline
      _fetchStationsWithMetadata().then((_) {
        _lastFullRefreshTime = DateTime.now();
        _lastFetchTimestamp = getRoundedTimestamp();
        _lastOffsetFetchTimestamp = 0;
        _preCacheStationThumbnails();
      });
    } else {
      // No cache: must wait for network
      PerformanceMonitor.startOperation('initial_stations_fetch');
      await _fetchStationsWithMetadata();
      PerformanceMonitor.endOperation('initial_stations_fetch');

      _lastFullRefreshTime = DateTime.now();
      _lastFetchTimestamp = getRoundedTimestamp();
      _lastOffsetFetchTimestamp = 0;
      _preCacheStationThumbnails();

      // Phase 3: Start lightweight differential metadata polling (every 10s)
      _isPolling = true;
      _pollTimer = Timer.periodic(_pollInterval, (_) => _pollMetadata());
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

  /// Fetches stations + metadata in parallel, merges, and applies in a single UI update.
  Future<void> _fetchStationsWithMetadata() async {
    try {
      // Same logic as _pollMetadata: offset only when HLS active + offset configured.
      final hlsActive = isPlayingHls?.call() ?? false;
      final configuredOffset = SeekModeManager.currentOffset;
      final hlsTimestamp = getHlsPlaybackTimestamp?.call();
      final int offsetTimestamp;
      final bool hasOffset;
      if (hlsTimestamp != null) {
        offsetTimestamp = hlsTimestamp;
        hasOffset = true;
      } else if (hlsActive && configuredOffset != Duration.zero) {
        final actualOffset = getActualPlaybackOffset?.call();
        offsetTimestamp = getRoundedTimestamp(offset: actualOffset ?? configuredOffset);
        hasOffset = true;
      } else {
        offsetTimestamp = getRoundedTimestamp();
        hasOffset = false;
      }
      final liveTimestamp = getRoundedTimestamp();

      final futures = <Future>[
        graphqlClient.query(
          Options$Query$GetStations(fetchPolicy: FetchPolicy.networkOnly),
        ),
        _fetchMetadata(liveTimestamp),
        if (hasOffset) _fetchMetadata(offsetTimestamp),
      ];
      final results = await Future.wait(futures);

      final stationsResult = results[0] as QueryResult<Query$GetStations>;
      final liveMetadata = results[1] as Map<int, Map<String, dynamic>>?;
      final offsetMetadata = hasOffset
          ? results[2] as Map<int, Map<String, dynamic>>?
          : liveMetadata;

      final parsedData = stationsResult.parsedData;
      if (parsedData != null && parsedData.stations.length >= _minStationsForCache) {
        final stationsWithMetadata = parsedData.stations.map((r) {
          var station = _createStation(r);
          final useOffset = _shouldUseOffsetMetadata(station);
          final primarySource = useOffset ? offsetMetadata : liveMetadata;
          final fallbackSource = useOffset ? liveMetadata : offsetMetadata;
          final metadata = primarySource?[station.id] ?? fallbackSource?[station.id];
          if (metadata != null) {
            final liveNowPlaying = liveMetadata?[station.id]?['now_playing'];
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
    } catch (e) {
      _log("Error fetching stations from API: $e");
    }
  }

  // ---------------------------------------------------------------------------
  // Metadata polling (differential updates)
  // ---------------------------------------------------------------------------

  Future<void> _pollMetadata() async {
    if (_isPollInFlight || stations.value.isEmpty) return;
    _isPollInFlight = true;

    try {
      // Check if it's time for a full refresh
      if (_lastFullRefreshTime != null &&
          DateTime.now().difference(_lastFullRefreshTime!) >= _fullRefreshInterval) {
        _log("Full refresh interval reached, performing full refresh");
        await _fetchStationsWithMetadata();
        _lastFullRefreshTime = DateTime.now();
        _lastFetchTimestamp = getRoundedTimestamp();
        _lastOffsetFetchTimestamp = 0;
        _preCacheStationThumbnails();
        return;
      }

      final liveTimestamp = getRoundedTimestamp();

      // Offset metadata is only needed when BOTH conditions are true:
      // 1. HLS is the active stream (non-HLS plays live, can't be delayed)
      // 2. The configured "încărcare în avans" offset is non-zero (not instant mode)
      // When either condition is false → live-only fetch for all stations.
      final hlsActive = isPlayingHls?.call() ?? false;
      final configuredOffset = SeekModeManager.currentOffset;
      final hlsTimestamp = getHlsPlaybackTimestamp?.call();
      final int offsetTimestamp;
      final bool hasOffset;
      if (hlsTimestamp != null) {
        // Precise HLS timestamp from EXT-X-PROGRAM-DATE-TIME
        offsetTimestamp = hlsTimestamp;
        hasOffset = true;
      } else if (hlsActive && configuredOffset != Duration.zero) {
        // HLS active with configured offset, but precise timestamp not yet available
        final actualOffset = getActualPlaybackOffset?.call();
        offsetTimestamp = getRoundedTimestamp(offset: actualOffset ?? configuredOffset);
        hasOffset = true;
      } else {
        // Not playing HLS, or instant mode → live only
        offsetTimestamp = liveTimestamp;
        hasOffset = false;
      }

      PerformanceMonitor.startOperation('poll_metadata');

      Map<int, Map<String, dynamic>>? liveMetadata;
      Map<int, Map<String, dynamic>>? offsetMetadata;

      if (!hasOffset) {
        // Single differential call when no seek offset is configured
        liveMetadata = await _fetchMetadata(liveTimestamp, changesFromTimestamp: _lastFetchTimestamp);
        offsetMetadata = liveMetadata;
      } else {
        // Differential offset only when the previous cursor is a sane reference:
        // not first poll in HLS mode, not a backward seek, and not so stale
        // that the saved value may belong to a different frame of reference
        // (synthetic offset vs precise PROGRAM-DATE-TIME) or strain server caches.
        final canDiffOffset = _lastOffsetFetchTimestamp > 0 &&
            offsetTimestamp > _lastOffsetFetchTimestamp &&
            (offsetTimestamp - _lastOffsetFetchTimestamp) <= _maxOffsetDiffGapSeconds;

        // Parallel: live (differential) + offset (differential when safe)
        final results = await Future.wait([
          _fetchMetadata(liveTimestamp, changesFromTimestamp: _lastFetchTimestamp),
          _fetchMetadata(
            offsetTimestamp,
            changesFromTimestamp: canDiffOffset ? _lastOffsetFetchTimestamp : null,
          ),
        ]);
        liveMetadata = results[0];
        offsetMetadata = results[1];
      }

      // Update last fetch timestamp for next differential query
      _lastFetchTimestamp = getRoundedTimestamp();
      if (hasOffset) {
        // Cursor must match the value sent on the request (server cache key).
        _lastOffsetFetchTimestamp = offsetTimestamp;
      }

      PerformanceMonitor.endOperation('poll_metadata');

      if (liveMetadata == null && offsetMetadata == null) {
        _log("Both metadata fetches failed, skipping update");
        return;
      }
      if (liveMetadata == null) _log("Live metadata fetch failed, using offset only");
      if (offsetMetadata == null) _log("Offset metadata fetch failed, using live only");

      // If differential returned empty (no changes), skip update for non-offset stations
      final hasLiveChanges = liveMetadata != null && liveMetadata.isNotEmpty;
      final hasOffsetChanges = offsetMetadata != null && offsetMetadata.isNotEmpty;

      if (!hasLiveChanges && !hasOffsetChanges) {
        _log("No metadata changes detected, skipping update");
        return;
      }

      final currentStations = stations.value;
      final updatedStations = currentStations.map((station) {
        final useOffset = _shouldUseOffsetMetadata(station);
        // Primary source based on stream type; fall back to the other if missing
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
        _log("Stations updated from differential metadata poll");

        // In unstable connection mode, pre-cache all song thumbnails permanently
        if (SeekModeManager.isUnstableConnection) {
          _preCacheSongThumbnails(updatedStations);
        }
      } else {
        _log("Stations unchanged after merge, skipping update");
      }
    } catch (e) {
      _log("Error in metadata poll: $e");
      // On metadata fetch failure, try a full refresh to recover
      try {
        _log("Attempting full refresh after poll failure");
        await _fetchStationsWithMetadata();
        _lastFullRefreshTime = DateTime.now();
        _lastFetchTimestamp = getRoundedTimestamp();
        _lastOffsetFetchTimestamp = 0;
      } catch (e2) {
        _log("Full refresh recovery also failed: $e2");
      }
    } finally {
      _isPollInFlight = false;
    }
  }

  /// Fetches metadata from REST API.
  /// When [changesFromTimestamp] is provided, only returns stations that changed
  /// since that timestamp (differential update, like radiocrestin.ro web app).
  Future<Map<int, Map<String, dynamic>>?> _fetchMetadata(
    int timestamp, {
    int? changesFromTimestamp,
  }) async {
    var url = '${CONSTANTS.STATIONS_METADATA_URL}?timestamp=$timestamp';
    if (changesFromTimestamp != null && changesFromTimestamp > 0) {
      url += '&changes_from_timestamp=$changesFromTimestamp';
    }
    try {
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body) as Map<String, dynamic>;
        final stationsMetadata = (jsonData['data']?['stations_metadata'] as List?) ?? [];
        final map = <int, Map<String, dynamic>>{};
        for (final item in stationsMetadata) {
          if (item is Map<String, dynamic> && item['id'] != null) {
            map[item['id'] as int] = item;
          }
        }
        return map;
      } else {
        _log("Metadata fetch failed: ${response.statusCode}");
        return null;
      }
    } catch (e) {
      _log("Error fetching metadata: $e");
      return null;
    }
  }

  /// Merges lightweight metadata (uptime, now_playing, listeners) into an existing station.
  /// Preserves all other fields (station_streams, posts, reviews, etc.).
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
