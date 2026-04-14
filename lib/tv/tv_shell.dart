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

/// TV app shell — full-screen, no sidebar, no persistent mini player.
/// Select a station → full-screen Now Playing.
/// Back → return to browse.
class TvShell extends StatefulWidget {
  const TvShell({super.key});

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  bool _showNowPlaying = false;

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
