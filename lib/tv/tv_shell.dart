import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../appAudioHandler.dart';
import '../types/Station.dart';
import 'tv_theme.dart';
import 'pages/tv_now_playing.dart';
import 'pages/tv_browse.dart';

/// TV app shell — two states:
///
/// 1. **Now Playing** (default): Full-screen artwork + metadata + controls.
///    Press BACK or DOWN → opens Browse.
///
/// 2. **Browse**: Immersive list overlay with station rows at the bottom.
///    Select a station → plays it, returns to Now Playing.
///    Press BACK → returns to Now Playing.
class TvShell extends StatefulWidget {
  const TvShell({super.key});

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  bool _browsing = false;

  late final AppAudioHandler _audioHandler;
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
    _currentStation = _audioHandler.currentStation.value;

    // Auto-play last station on startup
    if (_currentStation != null && !_audioHandler.playbackState.value.playing) {
      _audioHandler.play();
    }

    _subscriptions.add(
      _audioHandler.currentStation.stream.listen((station) {
        if (mounted) setState(() => _currentStation = station);
      }),
    );
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
    setState(() => _browsing = false); // Return to Now Playing
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
