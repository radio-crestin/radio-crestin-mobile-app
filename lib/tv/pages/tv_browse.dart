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

  // Owns initial focus on this page. When TvShell swaps the body from
  // Now Playing back to TvBrowse, the previous screen's play button
  // FocusNode is disposed but Flutter's FocusManager can keep primary
  // focus pointed at it — the first card *looked* focused while D-pad
  // keys went nowhere. By rooting TvBrowse in our own FocusScopeNode and
  // explicitly requesting focus on it after mount, we force the focus
  // chain into this subtree so the autofocused first card can claim it.
  final FocusScopeNode _scopeNode = FocusScopeNode(debugLabel: 'TvBrowse');

  // Cancellable so tests (and a quick exit) don't leak a pending timer.
  Timer? _focusRestoreTimer;

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

    // GridView.builder lazily mounts the cards, so the first card's
    // own autofocus postFrameCallback runs *later* than this initState
    // callback would. Wait a beat, then if no card has claimed primary
    // focus, walk this scope and focus the first focusable descendant.
    // After a short delay (long enough for GridView.builder to mount the
    // first row of cards), if no real focusable holds primary focus,
    // walk this page's scope and force focus onto the first focusable.
    // This recovers from the back-from-Now-Playing case where the
    // disposed play button left primary focus stranded.
    _focusRestoreTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final primary = FocusManager.instance.primaryFocus;
      final isFocusableLeaf = primary != null &&
          primary.context != null &&
          primary is! FocusScopeNode;
      if (isFocusableLeaf) return;
      for (final node in _scopeNode.descendants.toList()) {
        if (node.canRequestFocus &&
            !node.skipTraversal &&
            node is! FocusScopeNode) {
          node.requestFocus();
          return;
        }
      }
    });
  }

  @override
  void dispose() {
    _focusRestoreTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _scopeNode.dispose();
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
    // FocusScope owns this page's focus; the inner Focus only listens
    // for ESC/back keys bubbling up from cards.
    return FocusScope(
      node: _scopeNode,
      child: Focus(
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
                // Eager (non-builder) GridView so every card's DpadFocusable
                // mounts and registers with the dpad region manager. With
                // GridView.builder, off-viewport cards stay unmounted, so D-pad
                // traversal can't find them as candidates and gets stuck at the
                // last visible row (and gives jumpy L/R near the edges).
                // Station list is small (<100), so eager mount is fine.
                return GridView(
                  padding: EdgeInsets.fromLTRB(
                    marginH, 16, marginH, TvSpacing.lg,
                  ),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 8,
                    childAspectRatio: 160 / 216,
                  ),
                  children: [
                    for (var i = 0; i < stations.length; i++)
                      TvStationCard(
                        key: ValueKey(stations[i].id),
                        station: stations[i],
                        isPlaying: _currentStation?.id == stations[i].id,
                        isFavorite:
                            _favoriteSlugs.contains(stations[i].slug),
                        region: 'content',
                        isEntryPoint: i == 0,
                        autofocus: i == 0,
                        onSelect: () =>
                            widget.onStationSelected(stations[i]),
                        onFavoriteToggle: () {},
                      ),
                  ],
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
