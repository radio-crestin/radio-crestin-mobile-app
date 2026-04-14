import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../appAudioHandler.dart';
import '../services/station_data_service.dart';
import '../types/Station.dart';
import 'tv_theme.dart';
import 'pages/tv_now_playing.dart';
import 'pages/tv_browse.dart';

/// TV app — two pages:
///
/// 1. **Station page** (Now Playing): artwork + metadata + controls.
/// 2. **Station list** (Browse): scrollable station rows.
///
/// On startup: auto-plays the last station, or the first available.
/// Browse: focus previews station info, select plays + opens station page.
/// BACK from station page → browse. BACK from browse → station page.
class TvShell extends StatefulWidget {
  const TvShell({super.key});

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  late bool _browsing;
  bool _autoPlayDone = false;

  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];
  Station? _currentStation;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();
    _currentStation = _audioHandler.currentStation.value;

    // If station already loaded → station page. Otherwise → browse.
    _browsing = _currentStation == null;

    // Auto-play if station loaded but not playing
    if (_currentStation != null && !_audioHandler.playbackState.value.playing) {
      _audioHandler.play();
      _autoPlayDone = true;
    }

    _subscriptions.add(
      _audioHandler.currentStation.stream.listen((station) {
        if (mounted) setState(() => _currentStation = station);
      }),
    );

    // If no station loaded, auto-play the first one once stations arrive
    if (_currentStation == null) {
      _subscriptions.add(
        _stationDataService.stations.stream.listen((stations) {
          if (!_autoPlayDone && stations.isNotEmpty && mounted) {
            _autoPlayDone = true;
            _audioHandler.playStation(stations.first);
          }
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  void _openBrowse() => setState(() => _browsing = true);

  void _closeBrowse() => setState(() => _browsing = false);

  void _onStationSelected(Station station) {
    _audioHandler.playStation(station);
    setState(() => _browsing = false); // Go to station page
  }

  @override
  Widget build(BuildContext context) {
    return DpadNavigator(
      enabled: true,
      child: Scaffold(
        backgroundColor: TvColors.background,
        body: _browsing
            ? TvBrowse(
                onBack: _closeBrowse,
                onStationSelected: _onStationSelected,
              )
            : TvNowPlaying(
                onBrowse: _openBrowse,
              ),
      ),
    );
  }
}
