import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../appAudioHandler.dart';
import '../../types/Station.dart';
import '../tv_theme.dart';
import 'tv_browse.dart';

/// TV home shell: a single browse page (no tabs).
///
/// BACK on the home page opens Now Playing if a station is loaded;
/// otherwise it falls through and exits the app.
class TvHome extends StatefulWidget {
  final ValueChanged<Station> onStationSelected;
  final VoidCallback onOpenNowPlaying;

  /// Opens the TV settings page (contact QR + app info).
  final VoidCallback? onOpenSettings;

  /// Card to focus on mount (so returning from the player keeps position).
  final String? initialFocusKey;

  /// Reports the focused card key up to the shell to remember it.
  final ValueChanged<String>? onCardFocused;

  const TvHome({
    super.key,
    required this.onStationSelected,
    required this.onOpenNowPlaying,
    this.onOpenSettings,
    this.initialFocusKey,
    this.onCardFocused,
  });

  @override
  State<TvHome> createState() => _TvHomeState();
}

class _TvHomeState extends State<TvHome> {
  @override
  Widget build(BuildContext context) {
    final hasStation =
        GetIt.instance<AppAudioHandler>().currentStation.valueOrNull != null;
    return PopScope(
      canPop: !hasStation,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (hasStation) widget.onOpenNowPlaying();
      },
      child: ColoredBox(
        color: TvColors.background,
        child: SafeArea(
          child: TvBrowse(
            onBack: widget.onOpenNowPlaying,
            onStationSelected: widget.onStationSelected,
            onOpenSettings: widget.onOpenSettings,
            initialFocusKey: widget.initialFocusKey,
            onCardFocused: widget.onCardFocused,
          ),
        ),
      ),
    );
  }
}
