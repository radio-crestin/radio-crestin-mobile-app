import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../appAudioHandler.dart';
import '../types/Station.dart';
import 'tv_theme.dart';
import 'pages/tv_home_page.dart';
import 'pages/tv_now_playing_page.dart';

/// TV app shell — full-screen.
/// Starts with Now Playing if a station is already loaded (auto-resume).
/// Select a station from browse → full-screen Now Playing.
/// Back from Now Playing → browse.
class TvShell extends StatefulWidget {
  const TvShell({super.key});

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  late bool _showNowPlaying;

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

    // Start with Now Playing if a station is already loaded
    _currentStation = _audioHandler.currentStation.value;
    _showNowPlaying = _currentStation != null;

    // Auto-play the last station if it was loaded
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

  void _openNowPlaying() {
    if (_currentStation != null) {
      setState(() => _showNowPlaying = true);
    }
  }

  void _closeNowPlaying() {
    setState(() => _showNowPlaying = false);
  }

  @override
  Widget build(BuildContext context) {
    return DpadNavigator(
      enabled: true,
      child: Scaffold(
        backgroundColor: TvColors.background,
        body: _showNowPlaying
            ? TvNowPlayingPage(onBack: _closeNowPlaying)
            : TvHomePage(onOpenNowPlaying: _openNowPlaying),
      ),
    );
  }
}
