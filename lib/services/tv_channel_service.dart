import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/tv/tv_platform.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';

/// Bridges Flutter station data to the Android TV home screen channels API.
/// Publishes favorite stations as programs in a "Radio Crestin" channel
/// so users can pin them to the TV home screen for quick access.
class TvChannelService {
  static const _channel = MethodChannel('com.radiocrestin.tv_channels');

  final StationDataService _stationDataService =
      GetIt.instance<StationDataService>();
  final List<StreamSubscription> _subscriptions = [];

  Future<void> initialize() async {
    if (!Platform.isAndroid || !TvPlatform.isTV) return;

    // Handle native -> Dart calls (e.g. INITIALIZE_PROGRAMS broadcast)
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onInitializePrograms') {
        await _syncNow();
      }
    });

    // Subscribe to favorites + stations changes, debounced
    _subscriptions.add(
      Rx.combineLatest2<List<String>, List<Station>, List<Station>>(
        _stationDataService.favoriteStationSlugs.stream,
        _stationDataService.stations.stream,
        (favSlugs, allStations) {
          // Return only favorite stations, in favorites order
          final stationMap = {
            for (final s in allStations) s.slug as String: s,
          };
          return favSlugs
              .where((slug) => stationMap.containsKey(slug))
              .map((slug) => stationMap[slug]!)
              .toList();
        },
      ).debounceTime(const Duration(milliseconds: 500)).listen(
        (favoriteStations) => _syncChannel(favoriteStations),
      ),
    );

    developer.log('TvChannelService initialized', name: 'TvChannelService');
  }

  Future<void> _syncNow() async {
    final favSlugs = _stationDataService.favoriteStationSlugs.value;
    final allStations = _stationDataService.stations.value;
    final stationMap = {
      for (final s in allStations) s.slug as String: s,
    };
    final favorites = favSlugs
        .where((slug) => stationMap.containsKey(slug))
        .map((slug) => stationMap[slug]!)
        .toList();
    await _syncChannel(favorites);
  }

  Future<void> _syncChannel(List<Station> stations) async {
    try {
      final data = stations
          .map((s) => {
                'slug': s.slug as String,
                'title': s.title as String,
                'thumbnailUrl': s.thumbnailUrl,
                'songTitle': s.songTitle,
              })
          .toList();

      await _channel.invokeMethod('syncFavoriteChannel', data);
    } catch (e) {
      developer.log('Failed to sync TV channel: $e',
          name: 'TvChannelService', level: 900);
    }
  }

  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
  }
}
