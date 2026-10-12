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
    if (!Platform.isAndroid || !TvPlatform.isTV) {
      developer.log(
          'Skipped: Platform.isAndroid=${Platform.isAndroid} '
          'TvPlatform.isTV=${TvPlatform.isTV}',
          name: 'TvChannelService');
      return;
    }

    // Handle native -> Dart calls (e.g. INITIALIZE_PROGRAMS broadcast)
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onInitializePrograms') {
        final stations = _stationDataService.stations.value;
        developer.log(
            'onInitializePrograms received, ${stations.length} stations',
            name: 'TvChannelService');
        if (stations.isNotEmpty) await _syncChannel(stations);
      }
    });

    // Publish ALL stations to the TV home screen channel so users can
    // pin any station they want. Listen on `.stream` (replays the seed
    // value to new subscribers) and skip empty seeds; debounce so we
    // batch the GraphQL initial load + first poll into one sync.
    // Native only inserts new slugs and deletes gone ones, so song-only
    // updates are dropped here instead of costing two TV-provider queries.
    _subscriptions.add(
      _stationDataService.stations.stream
          .where((stations) => stations.isNotEmpty)
          .distinct((a, b) => _channelKey(a) == _channelKey(b))
          .debounceTime(const Duration(milliseconds: 1000))
          .listen((stations) => _syncChannel(stations)),
    );

    developer.log('initialized, awaiting non-empty stations',
        name: 'TvChannelService');
  }

  /// What the home-screen channel shows per station. Deliberately excludes
  /// `songTitle`, which changes every few minutes and native ignores.
  static String _channelKey(List<Station> stations) => stations
      .map((s) => '${s.slug}|${s.title}|${s.thumbnailUrl}')
      .join('\n');

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

      developer.log('syncFavoriteChannel → native (${data.length} stations)',
          name: 'TvChannelService');
      final ok = await _channel.invokeMethod('syncFavoriteChannel', data);
      developer.log('synced: native returned $ok',
          name: 'TvChannelService');
    } catch (e, st) {
      developer.log('sync failed: $e\n$st',
          name: 'TvChannelService', level: 900);
    }
  }

  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
  }
}
