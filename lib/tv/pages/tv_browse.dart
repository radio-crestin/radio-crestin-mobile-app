import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../services/station_data_service.dart';
import '../../services/station_sort_service.dart';
import '../../services/play_count_service.dart';
import '../../types/Station.dart';
import '../tv_theme.dart';
import '../widgets/tv_station_card.dart';

/// TV homepage — single grid of all stations sorted "Pentru tine".
///
/// Brand mark on top, "Pentru tine" section header, then a grid of
/// station cards. ESC / BACK returns to Now Playing.
class TvBrowse extends StatefulWidget {
  final VoidCallback onBack;
  final ValueChanged<Station> onStationSelected;

  const TvBrowse({
    super.key,
    required this.onBack,
    required this.onStationSelected,
  });

  @override
  State<TvBrowse> createState() => _TvBrowseState();
}

class _TvBrowseState extends State<TvBrowse> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];

  Station? _currentStation;
  List<Station> _allStations = [];
  List<String> _favoriteSlugs = [];

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();

    _subscriptions.add(
      Rx.combineLatest3(
        _audioHandler.currentStation.stream,
        _stationDataService.stations.stream,
        _stationDataService.favoriteStationSlugs.stream,
        (Station? current, List<Station> all, List<String> favs) =>
            (current, all, favs),
      ).listen((data) {
        if (mounted) {
          setState(() {
            _currentStation = data.$1;
            _allStations = data.$2;
            _favoriteSlugs = data.$3;
          });
        }
      }),
    );

    // Returning to the homepage from Now Playing left primary focus
    // pointed at the just-disposed play button: the first card *looked*
    // focused but D-pad keys went nowhere because the focused node was
    // a dead reference. Run two passes after the first frame:
    //
    //   1. drop the stale primary focus so the card's own autofocus
    //      can claim it; and
    //   2. on the *next* frame (post-card-mount), as a belt-and-braces
    //      fallback, walk the scope and force focus onto the first
    //      focusable if nobody picked it up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final primary = FocusManager.instance.primaryFocus;
        if (primary != null && primary.context != null) return;
        FocusScope.of(context).focusInDirection(TraversalDirection.down);
      });
    });
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  List<Station> get _sortedStations {
    final playCounts = GetIt.instance<PlayCountService>().playCounts;
    return StationSortService.sort(
      stations: List<Station>.from(_allStations),
      sortBy: StationSortOption.recommended,
      playCounts: playCounts,
      favoriteSlugs: _favoriteSlugs,
    ).sorted;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      widget.onBack();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // canRequestFocus: false so this wrapper doesn't compete with the
    // autofocused first card for initial focus — it only listens for
    // ESC/back keys bubbling up from descendants.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKeyEvent,
      child: ColoredBox(
        color: TvColors.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Header(),
            Expanded(child: _buildGrid()),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid() {
    final stations = _sortedStations;
    if (stations.isEmpty) {
      return Center(
        child: Text('Nu sunt posturi', style: TvTypography.body),
      );
    }

    final marginH = TvSpacing.marginHorizontal;
    return Padding(
      padding: const EdgeInsets.only(top: TvSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: marginH),
            child: Padding(
              padding: const EdgeInsets.only(bottom: TvSpacing.sm),
              child: Row(
                children: [
                  const Icon(
                    Icons.auto_awesome,
                    size: 22,
                    color: Color(0xFFF59E0B),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Pentru tine',
                    style: TvTypography.headline.copyWith(fontSize: 22),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Cells fall back from the screen edge by `marginH` so the
                // focused card's outer ring + glow has breathing room and
                // doesn't get sliced off at the GridView's left/right edge.
                final usable = constraints.maxWidth - marginH * 2;
                final columns = (usable / 190).floor().clamp(2, 10);
                return GridView.builder(
                  padding: EdgeInsets.fromLTRB(
                    marginH, 16, marginH, TvSpacing.lg,
                  ),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 8,
                    childAspectRatio: 160 / 216,
                  ),
                  itemCount: stations.length,
                  itemBuilder: (_, i) {
                    final s = stations[i];
                    return TvStationCard(
                      station: s,
                      isPlaying: _currentStation?.id == s.id,
                      isFavorite: _favoriteSlugs.contains(s.slug),
                      region: 'content',
                      isEntryPoint: i == 0,
                      autofocus: i == 0,
                      onSelect: () => widget.onStationSelected(s),
                      onFavoriteToggle: () {},
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Header: brand mark only.
// ─────────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: TvHeaderBar.height,
      padding: EdgeInsets.symmetric(
        horizontal: TvSpacing.marginHorizontal,
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: TvColors.primary,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.radio_rounded,
                color: Colors.white, size: 22),
          ),
          const SizedBox(width: TvSpacing.sm),
          const Text(
            'Radio Crestin',
            style: TextStyle(
              color: TvColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
        ],
      ),
    );
  }
}
