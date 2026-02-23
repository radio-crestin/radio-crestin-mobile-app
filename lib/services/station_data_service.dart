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
import 'package:radio_crestin/queries/getStations.graphql.dart';
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
  static const _pollInterval = Duration(seconds: 5);

  /// Returns the actual stream type ('HLS', 'direct_stream', etc.) if the given
  /// station ID is currently playing, or null if it's not the active station.
  /// Set by AppAudioHandler after init to avoid circular dependency.
  String? Function(int stationId)? getPlayingStreamType;

  // Streams
  final BehaviorSubject<List<Station>> stations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<Station>> filteredStations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<String>> favoriteStationSlugs = BehaviorSubject.seeded([]);
  final BehaviorSubject<List<Query$GetStations$station_groups>> stationGroups =
      BehaviorSubject.seeded(<Query$GetStations$station_groups>[]);
  final BehaviorSubject<Query$GetStations$station_groups?> selectedStationGroup =
      BehaviorSubject.seeded(null);

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

  Future<void> refreshStations() async {
    _log("Manually refreshing stations");
    await _fetchStationsWithMetadata();
    _preCacheStationThumbnails();
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
    if (cached != null) {
      _log("Loaded ${cached.stations.length} stations from cache");
      _applyStationsData(cached);
    } else {
      final fallback = await _loadFallbackStations();
      if (fallback != null) {
        _log("Loaded ${fallback.stations.length} stations from bundled fallback");
        _applyStationsData(fallback);
      }
    }

    // Phase 2: Fetch stations + metadata in parallel, merge, apply once
    PerformanceMonitor.startOperation('initial_stations_fetch');
    await _fetchStationsWithMetadata();
    PerformanceMonitor.endOperation('initial_stations_fetch');

    _preCacheStationThumbnails();

    // Phase 3: Start lightweight metadata polling
    _isPolling = true;
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollMetadata());
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

  void _applyStationsData(Query$GetStations data) {
    stations.add(data.stations.map((r) => Station(rawStationData: r)).toList());
    stationGroups.add(data.station_groups);
  }

  /// Fetches stations + metadata in parallel, merges, and applies in a single UI update.
  Future<void> _fetchStationsWithMetadata() async {
    try {
      final offset = SeekModeManager.currentOffset;
      final liveTimestamp = getRoundedTimestamp();
      final offsetTimestamp = getRoundedTimestamp(offset: offset);

      final futures = <Future>[
        graphqlClient.query(
          Options$Query$GetStations(fetchPolicy: FetchPolicy.networkOnly),
        ),
        _fetchMetadata(liveTimestamp),
        if (offset != Duration.zero) _fetchMetadata(offsetTimestamp),
      ];
      final results = await Future.wait(futures);

      final stationsResult = results[0] as QueryResult<Query$GetStations>;
      final liveMetadata = results[1] as Map<int, Map<String, dynamic>>?;
      final offsetMetadata = offset != Duration.zero
          ? results[2] as Map<int, Map<String, dynamic>>?
          : liveMetadata;

      final parsedData = stationsResult.parsedData;
      if (parsedData != null && parsedData.stations.length >= _minStationsForCache) {
        final stationsWithMetadata = parsedData.stations.map((r) {
          var station = Station(rawStationData: r);
          final useOffset = _shouldUseOffsetMetadata(station);
          final metadataSource = useOffset ? offsetMetadata : liveMetadata;
          final metadata = metadataSource?[station.id];
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
  // Metadata polling
  // ---------------------------------------------------------------------------

  Future<void> _pollMetadata() async {
    if (_isPollInFlight || stations.value.isEmpty) return;
    _isPollInFlight = true;

    try {
      final liveTimestamp = getRoundedTimestamp();
      final offset = SeekModeManager.currentOffset;
      final offsetTimestamp = getRoundedTimestamp(offset: offset);

      PerformanceMonitor.startOperation('poll_metadata');

      Map<int, Map<String, dynamic>>? liveMetadata;
      Map<int, Map<String, dynamic>>? offsetMetadata;

      if (offset == Duration.zero) {
        // Single call when no seek offset is configured
        liveMetadata = await _fetchMetadata(liveTimestamp);
        offsetMetadata = liveMetadata;
      } else {
        // Parallel: live timestamp for non-HLS, offset timestamp for HLS
        final results = await Future.wait([
          _fetchMetadata(liveTimestamp),
          _fetchMetadata(offsetTimestamp),
        ]);
        liveMetadata = results[0];
        offsetMetadata = results[1];
      }

      PerformanceMonitor.endOperation('poll_metadata');

      if (liveMetadata == null && offsetMetadata == null) {
        _log("Both metadata fetches failed, skipping update");
        return;
      }
      if (liveMetadata == null) _log("Live metadata fetch failed, using offset only");
      if (offsetMetadata == null) _log("Offset metadata fetch failed, using live only");

      final currentStations = stations.value;
      final updatedStations = currentStations.map((station) {
        final useOffset = _shouldUseOffsetMetadata(station);
        final metadataSource = useOffset ? offsetMetadata : liveMetadata;
        final metadata = metadataSource?[station.id];
        if (metadata == null) return station;
        final liveNowPlaying = liveMetadata?[station.id]?['now_playing'];
        final liveListeners = liveNowPlaying is Map<String, dynamic>
            ? liveNowPlaying['listeners'] as int?
            : null;
        return _mergeStationWithMetadata(station, metadata, liveListeners: liveListeners);
      }).toList();

      if (_hasStationsChanged(currentStations, updatedStations)) {
        stations.add(updatedStations);
        _log("Stations updated from metadata poll");
      } else {
        _log("Stations unchanged, skipping update");
      }
    } finally {
      _isPollInFlight = false;
    }
  }

  Future<Map<int, Map<String, dynamic>>?> _fetchMetadata(int timestamp) async {
    final url = '${CONSTANTS.STATIONS_METADATA_URL}?timestamp=$timestamp';
    try {
      final response = await http.get(Uri.parse(url));
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

    return Station(rawStationData: Query$GetStations$stations.fromJson(stationJson));
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
}
