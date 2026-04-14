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
/// Publishes all stations as programs in a "Radio Crestin" channel
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
        final stations = _stationDataService.stations.value;
        if (stations.isNotEmpty) await _syncChannel(stations);
      }
    });

    // Publish ALL stations to the TV home screen channel so users can
    // pin any station they want. Use the BehaviorSubject directly (not
    // .stream) so the current value replays immediately on subscribe.
    _subscriptions.add(
      _stationDataService.stations
          .where((stations) => stations.isNotEmpty)
          .debounceTime(const Duration(milliseconds: 1000))
          .listen((stations) => _syncChannel(stations)),
    );

    developer.log('TvChannelService initialized', name: 'TvChannelService');
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
      developer.log('TV channel synced: ${data.length} stations',
          name: 'TvChannelService');
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
