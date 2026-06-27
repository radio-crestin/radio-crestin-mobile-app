import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../tv_theme.dart';
import '../widgets/desktop_focusable.dart';
import '../widgets/tv_station_card.dart';

/// TV homepage — two sections, each a multi-row grid:
///   • "Favorite" (only when the user has favorites)
///   • "Pentru tine" (the session-frozen recommended order)
///
/// The order is the frozen recommended order (see
/// [StationDataService.orderedStations]) so cards never reshuffle while the
/// user plays stations — which also keeps the D-pad focus tree stable.
///
/// Scrolling is handled entirely by dpad's smooth focus-follow (the vendored
/// fork drops Flutter's instant ensureVisible jump). A generous `cacheExtent`
/// keeps the rows just off-screen mounted so D-pad can always reach the row
/// above/below.
///
/// BACK is handled exclusively by [TvHome]'s PopScope — there is intentionally
/// no raw key handler here (that previously double-handled one BACK press).
class TvBrowse extends StatefulWidget {
  final VoidCallback onBack;
  final ValueChanged<Station> onStationSelected;

  /// Opens the TV settings page from the header button.
  final VoidCallback? onOpenSettings;

  /// Composite key (`s-stationId`) of the card to focus on mount, so returning
  /// from the player lands on the same card / scroll position.
  final String? initialFocusKey;

  /// Reports the focused card's composite key up to the shell so it can be
  /// restored on the next mount.
  final ValueChanged<String>? onCardFocused;

  const TvBrowse({
    super.key,
    required this.onBack,
    required this.onStationSelected,
    this.onOpenSettings,
    this.initialFocusKey,
    this.onCardFocused,
  });

  @override
  State<TvBrowse> createState() => _TvBrowseState();
}

class _TvBrowseState extends State<TvBrowse> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];

  // Owns initial focus on this page. When TvShell swaps the body from Now
  // Playing back to TvBrowse, the previous screen's play button FocusNode is
  // disposed but Flutter's FocusManager can keep primary focus pointed at it.
  // Rooting TvBrowse in our own FocusScopeNode lets the focus-restore timer
  // force focus back into this subtree.
  final FocusScopeNode _scopeNode = FocusScopeNode(debugLabel: 'TvBrowse');
  final ScrollController _scrollController = ScrollController();

  Timer? _focusRestoreTimer;

  Station? _currentStation;
  List<Station> _allStations = [];
  List<String> _favoriteSlugs = [];

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();

    // Seed synchronously from the in-memory streams so the first frame already
    // shows the stations (no empty flash) when returning to this page.
    _currentStation = _audioHandler.currentStation.valueOrNull;
    _allStations = _stationDataService.orderedStations.value;
    _favoriteSlugs = _stationDataService.favoriteStationSlugs.value;

    _subscriptions.add(
      Rx.combineLatest3(
        _audioHandler.currentStation.stream,
        _stationDataService.orderedStations.stream,
        _stationDataService.favoriteStationSlugs.stream,
        (Station? cur, List<Station> all, List<String> favs) =>
            (cur, all, favs),
      ).listen((data) {
        if (!mounted) return;
        setState(() {
          _currentStation = data.$1;
          _allStations = data.$2;
          _favoriteSlugs = data.$3;
        });
      }),
    );

    // After a short delay (long enough for the grid's first cards to mount),
    // if no real focusable holds primary focus, walk this page's scope and
    // force focus onto the first focusable. Recovers the back-from-Now-Playing
    // case where the disposed play button left primary focus stranded.
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
    _scrollController.dispose();
    _scopeNode.dispose();
    super.dispose();
  }

  /// Stations in display order: favorites first (keeping the frozen recommended
  /// order), then everyone else. A single "Pentru tine" list — no separate
  /// favorites section.
  List<Station> get _displayStations {
    final favSet = _favoriteSlugs.toSet();
    final favs = <Station>[];
    final rest = <Station>[];
    for (final s in _allStations) {
      (favSet.contains(s.slug) ? favs : rest).add(s);
    }
    return [...favs, ...rest];
  }

  /// The card key to focus on this build: the remembered one if it's still on
  /// screen, otherwise the first card.
  String? _focusKeyFor(List<Station> stations) {
    final keys = {for (final s in stations) 's-${s.id}'};
    final remembered = widget.initialFocusKey;
    if (remembered != null && keys.contains(remembered)) return remembered;
    if (stations.isNotEmpty) return 's-${stations.first.id}';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final stations = _displayStations;
    final hasStations = stations.isNotEmpty;
    final focusKey = _focusKeyFor(stations);
    final current = _currentStation;

    return FocusScope(
      node: _scopeNode,
      child: ColoredBox(
        color: TvColors.background,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(onOpenSettings: widget.onOpenSettings),
              Expanded(
                child: !hasStations
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: TvColors.primary, strokeWidth: 2.5),
                      )
                    : CustomScrollView(
                        controller: _scrollController,
                        // Keep effectively the whole list laid out (station
                        // count is small) so D-pad can always reach any row,
                        // dpad never reads a recycled/defunct focus node, and
                        // returning from the player can restore focus to any
                        // remembered card regardless of depth.
                        cacheExtent: 5000,
                        slivers: [
                          // Now-playing shortcut at the very top. Focusable —
                          // selecting it (re)opens the full player.
                          if (current != null)
                            SliverToBoxAdapter(
                              child: _NowPlayingTile(
                                station: current,
                                onOpen: widget.onBack,
                              ),
                            ),
                          // Single "For you" list — favorites first, then the
                          // rest (no separate favorites section).
                          _SectionHeader(
                            icon: Icons.auto_awesome,
                            iconColor: const Color(0xFFF59E0B),
                            title: 'Pentru tine',
                          ),
                          _grid(stations, focusKey),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: TvSpacing.lg),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _grid(List<Station> stations, String? focusKey) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
          TvSpacing.marginHorizontal, 6, TvSpacing.marginHorizontal, 12),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisExtent: 224,
          crossAxisSpacing: 12,
          mainAxisSpacing: 8,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final station = stations[index];
            final key = 's-${station.id}';
            return Center(
              child: TvStationCard(
                key: ValueKey(key),
                station: station,
                isPlaying: _currentStation?.id == station.id,
                isFavorite: _favoriteSlugs.contains(station.slug),
                region: 'content',
                autofocus: key == focusKey,
                isEntryPoint: key == focusKey,
                onSelect: () => widget.onStationSelected(station),
                onFavoriteToggle: () {},
                onFocus: (_) => widget.onCardFocused?.call(key),
              ),
            );
          },
          childCount: stations.length,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Section header (icon + title), scrolls with the grid.
// ─────────────────────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;

  const _SectionHeader({
    required this.icon,
    required this.iconColor,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            TvSpacing.marginHorizontal, TvSpacing.sm, TvSpacing.marginHorizontal, 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 8),
            Text(
              title,
              style: TvTypography.headline
                  .copyWith(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Header: brand mark only.
// ─────────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  final VoidCallback? onOpenSettings;
  const _Header({this.onOpenSettings});

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
          const Spacer(),
          if (onOpenSettings != null) _SettingsButton(onOpen: onOpenSettings!),
        ],
      ),
    );
  }
}

// Focusable settings (gear) button in the header — opens the TV settings page.
class _SettingsButton extends StatelessWidget {
  final VoidCallback onOpen;
  const _SettingsButton({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return DesktopFocusable(
      region: 'content',
      onSelect: onOpen,
      builder: (context, isFocused, child) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: isFocused ? TvColors.primary : TvColors.surfaceVariant,
            shape: BoxShape.circle,
            border: Border.all(
              color: isFocused ? TvColors.primary : Colors.transparent,
              width: 2,
            ),
            boxShadow: isFocused
                ? [
                    BoxShadow(
                      color: TvColors.primary.withValues(alpha: 0.4),
                      blurRadius: 14,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            Icons.settings_rounded,
            color: isFocused ? Colors.white : TvColors.textPrimary,
            size: 22,
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Now-playing tile: the current station pinned at the top of the browse
// list. Focusable — selecting it (re)opens the full player. Reachable by
// pressing UP from the first grid row.
// ─────────────────────────────────────────────────────────────────────
class _NowPlayingTile extends StatelessWidget {
  final Station station;
  final VoidCallback onOpen;

  const _NowPlayingTile({required this.station, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(TvSpacing.marginHorizontal, TvSpacing.sm,
          TvSpacing.marginHorizontal, 0),
      child: DesktopFocusable(
        region: 'content',
        onSelect: onOpen,
        builder: (context, isFocused, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: isFocused
                  ? TvColors.primary.withValues(alpha: 0.18)
                  : TvColors.surfaceVariant,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isFocused ? TvColors.primary : Colors.transparent,
                width: 3,
              ),
              boxShadow: isFocused
                  ? [
                      BoxShadow(
                        color: TvColors.primary.withValues(alpha: 0.4),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: child,
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: station.displayThumbnail(cacheWidth: 160),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.equalizer_rounded,
                            color: TvColors.primary, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          'Se redă acum',
                          style: TvTypography.caption.copyWith(
                            color: TvColors.primary,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      station.title,
                      style: TvTypography.headline
                          .copyWith(fontSize: 20, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (station.songTitle.isNotEmpty)
                      Text(
                        station.songTitle,
                        style: TvTypography.caption.copyWith(
                            fontSize: 13, color: TvColors.textTertiary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              const Icon(Icons.play_circle_fill_rounded,
                  color: TvColors.primary, size: 40),
            ],
          ),
        ),
      ),
    );
  }
}
