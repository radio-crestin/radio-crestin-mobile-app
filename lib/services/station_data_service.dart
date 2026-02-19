import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/performance_monitor.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/services/image_cache_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StationDataService {
  final GraphQLClient graphqlClient;
  late StreamSubscription<QueryResult<Query$GetStations>> _watchStations;

  final BehaviorSubject<List<Station>> stations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<Station>> filteredStations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<String>> favoriteStationSlugs = BehaviorSubject.seeded([]);
  final BehaviorSubject<List<Query$GetStations$station_groups>> stationGroups =
      BehaviorSubject.seeded(<Query$GetStations$station_groups>[]);
  final BehaviorSubject<Query$GetStations$station_groups?> selectedStationGroup =
      BehaviorSubject.seeded(null);

  static const _favoriteStationsKey = 'favoriteStationSlugs';

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

  _log(String message) {
    developer.log("StationDataService: $message");
  }

  Future<void> initialize() async {
    _initFilteredStationsStream();
    await _initFavoriteStationSlugs();
    _setupRefreshStations();
  }

  Future<void> _initFavoriteStationSlugs() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? favoriteJson = prefs.getString(_favoriteStationsKey);
    List<String> newFavoriteStationSlugs = [];
    if (favoriteJson != null) {
      newFavoriteStationSlugs = List<String>.from(json.decode(favoriteJson));
    }
    favoriteStationSlugs.add(newFavoriteStationSlugs);
  }

  void _initFilteredStationsStream() {
    final combinedStream =
        Rx.combineLatest2<Query$GetStations$station_groups?, List<Station>, List<Station>>(
      selectedStationGroup.stream,
      stations.stream,
      (selectedGroup, allStations) {
        allStations.sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
        if (selectedGroup == null) {
          return allStations;
        }
        selectedGroup.station_to_station_groups.sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
        final selectedStationsIds =
            selectedGroup.station_to_station_groups.map((e) => e.station_id);
        return allStations.where((station) {
          return selectedStationsIds.contains(station.id);
        }).toList();
      },
    );
    combinedStream.listen((filteredStationsList) {
      filteredStations.add(filteredStationsList);
    });
  }

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

  Future<Query$GetStations?> _loadFallbackStations() async {
    try {
      _log("Loading fallback stations from asset");
      final jsonString = await rootBundle.loadString('assets/fallback-stations.json');
      final data = (json.decode(jsonString) as Map<String, dynamic>)['data'] as Map<String, dynamic>;
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
    _preCacheStationThumbnails();
  }

  void _setupRefreshStations() async {
    _log("Starting to fetch stations");

    // Load fallback immediately so UI has data right away
    final fallback = await _loadFallbackStations();
    if (fallback != null) _applyStationsData(fallback);

    // Fetch from API (replaces fallback when ready)
    PerformanceMonitor.startOperation('initial_stations_fetch');
    try {
      final parsedData = (await graphqlClient.query(Options$Query$GetStations())).parsedData;
      if (parsedData != null && parsedData.stations.isNotEmpty) {
        _applyStationsData(parsedData);
      }
    } catch (e) {
      _log("Error fetching stations from API: $e");
    }
    PerformanceMonitor.endOperation('initial_stations_fetch');

    // Poll for live updates every 5 seconds
    _watchStations = graphqlClient
        .watchQuery$GetStations(
          WatchOptions$Query$GetStations(
            fetchPolicy: FetchPolicy.cacheAndNetwork,
            errorPolicy: ErrorPolicy.all,
            cacheRereadPolicy: CacheRereadPolicy.ignoreAll,
            pollInterval: const Duration(seconds: 5),
            fetchResults: true,
          ),
        )
        .stream
        .listen((event) async {
      _log("Done fetching stations");
      final parsedData = event.parsedData;
      if (parsedData == null) {
        _log("No data");
        return;
      }
      final newStations = parsedData.stations
          .map((rawStationData) => Station(rawStationData: rawStationData))
          .toList();

      if (_hasStationsChanged(stations.value, newStations)) {
        stations.add(newStations);
        stationGroups.add(parsedData.station_groups);
        _preCacheStationThumbnails();
      } else {
        _log("Stations unchanged, skipping update");
      }
    });
  }

  void _preCacheStationThumbnails() {
    final urls = stations.value
        .where((s) => s.thumbnailUrl != null && s.thumbnailUrl!.isNotEmpty)
        .map((s) => s.thumbnailUrl!)
        .toList();
    if (urls.isEmpty) return;
    ImageCacheService.instance.preCacheUrls(urls);
  }

  Future<void> refreshStations() async {
    _log("Manually refreshing stations");
    try {
      final result = await graphqlClient.query(
        Options$Query$GetStations(
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );
      final parsedData = result.parsedData;
      if (parsedData != null) {
        stations.add((parsedData.stations)
            .map((rawStationData) => Station(rawStationData: rawStationData))
            .toList());
        stationGroups.add(parsedData.station_groups);
        _preCacheStationThumbnails();
      }
    } catch (e) {
      _log("Error refreshing stations: $e");
    }
  }

  Future<void> setStationIsFavorite(Station station, bool isFavorite) async {
    developer.log("setStationIsFavorite: ${station.slug} $isFavorite");
    if (isFavorite) {
      favoriteStationSlugs.add([...favoriteStationSlugs.value, station.slug]);
    } else {
      favoriteStationSlugs
          .add(favoriteStationSlugs.value.where((slug) => slug != station.slug).toList());
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_favoriteStationsKey, json.encode(favoriteStationSlugs.value));
  }

  void cancelWatchStations() {
    _watchStations.cancel();
  }
}
