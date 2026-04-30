import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../appAudioHandler.dart';
import '../../types/Station.dart';
import '../tv_theme.dart';
import '../widgets/tv_left_rail.dart';
import 'tv_browse.dart';
import 'tv_favorites_page.dart';
import 'tv_recent_page.dart';
import 'tv_settings_page.dart';

/// TV home shell: left navigation rail + IndexedStack of the 4 sections.
///
/// Stations / Favorite / Recente / Setări. Each tab keeps its own focus
/// memory so D-pad LEFT returns to the rail and DOWN/RIGHT enters the
/// content. Now Playing is reached by selecting a station inside any tab.
class TvHome extends StatefulWidget {
  final ValueChanged<Station> onStationSelected;
  final VoidCallback onOpenNowPlaying;

  const TvHome({
    super.key,
    required this.onStationSelected,
    required this.onOpenNowPlaying,
  });

  @override
  State<TvHome> createState() => _TvHomeState();
}

class _TvHomeState extends State<TvHome> {
  int _index = 0;

  // Keep one widget per tab alive so scroll/focus state survives switches.
  late final List<Widget> _pages = [
    TvBrowse(
      onBack: widget.onOpenNowPlaying,
      onStationSelected: widget.onStationSelected,
    ),
    TvFavoritesPage(onOpenNowPlaying: widget.onOpenNowPlaying),
    TvRecentPage(onOpenNowPlaying: widget.onOpenNowPlaying),
    const TvSettingsPage(),
  ];

  static const _railItems = <TvLeftRailItem>[
    TvLeftRailItem(icon: Icons.radio_rounded, label: 'Stații'),
    TvLeftRailItem(icon: Icons.favorite_rounded, label: 'Favorite'),
    TvLeftRailItem(icon: Icons.history_rounded, label: 'Recente'),
    TvLeftRailItem(icon: Icons.settings_rounded, label: 'Setări'),
  ];

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    // Number keys 1-4 jump straight to a tab. Useful with keyboards and the
    // numeric keypad on some TV remotes.
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.digit1) {
      setState(() => _index = 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit2) {
      setState(() => _index = 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit3) {
      setState(() => _index = 2);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit4) {
      setState(() => _index = 3);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final hasStation =
        GetIt.instance<AppAudioHandler>().currentStation.valueOrNull != null;
    return PopScope(
      // BACK semantics:
      //   non-Stations tab → return to Stations (single source of truth so
      //     hidden IndexedStack children don't double-intercept)
      //   Stations tab + a station is loaded → open Now Playing so the
      //     user can resume listening; otherwise fall through and exit.
      canPop: _index == 0 && !hasStation,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_index != 0) {
          setState(() => _index = 0);
        } else if (hasStation) {
          widget.onOpenNowPlaying();
        }
      },
      child: Focus(
        onKeyEvent: _onKeyEvent,
        child: ColoredBox(
          color: TvColors.background,
          child: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TvLeftRail(
                  items: _railItems,
                  selectedIndex: _index,
                  onSelect: (i) => setState(() => _index = i),
                ),
                Expanded(
                  child: IndexedStack(
                    index: _index,
                    children: _pages,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
