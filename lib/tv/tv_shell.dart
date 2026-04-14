import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../appAudioHandler.dart';
import 'tv_theme.dart';
import 'pages/tv_main_page.dart';

/// TV app shell — single unified page.
/// Now Playing background + station browser overlaid at bottom.
class TvShell extends StatefulWidget {
  const TvShell({super.key});

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // Auto-play last station on TV startup
    final audioHandler = GetIt.instance<AppAudioHandler>();
    if (audioHandler.currentStation.value != null &&
        !audioHandler.playbackState.value.playing) {
      audioHandler.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DpadNavigator(
      enabled: true,
      child: const Scaffold(
        backgroundColor: TvColors.background,
        body: TvMainPage(),
      ),
    );
  }
}
