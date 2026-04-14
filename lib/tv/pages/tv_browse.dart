import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../queries/getStations.graphql.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../tv_platform.dart';
import '../tv_theme.dart';
import '../widgets/desktop_focusable.dart';
import '../widgets/tv_station_card.dart';
import '../widgets/tv_station_row.dart';

/// Station list page (Browse).
///
/// On Android TV: horizontal rows (Favorites → Categories).
/// On Desktop: category tabs at top + responsive vertical grid.
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
  List<Query$GetStations$station_groups> _groups = [];

  /// Currently selected category for desktop grid view.
  String _selectedCategory = _kForYou;
  static const String _kForYou = 'Pentru tine';
  static const String _kFavorites = 'Favorite';

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();

    _subscriptions.add(
      Rx.combineLatest4(
        _audioHandler.currentStation.stream,
        _stationDataService.stations.stream,
        _stationDataService.favoriteStationSlugs.stream,
        _stationDataService.stationGroups.stream,
        (Station? current, List<Station> all, List<String> favs,
                List<Query$GetStations$station_groups> groups) =>
            (current, all, favs, groups),
      ).listen((data) {
        if (mounted) {
          setState(() {
            _currentStation = data.$1;
            _allStations = data.$2;
            _favoriteSlugs = data.$3;
            _groups = data.$4;
          });
        }
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

  List<Station> get _favoriteStations =>
      _allStations.where((s) => _favoriteSlugs.contains(s.slug)).toList();

  Map<String, List<Station>> get _groupedStations {
    final stationMap = {for (final s in _allStations) s.id: s};
    final map = <String, List<Station>>{};
    for (final group in _groups) {
      final ids =
          group.station_to_station_groups.map((e) => e.station_id).toSet();
      final list = ids
          .where((id) => stationMap.containsKey(id))
          .map((id) => stationMap[id]!)
          .toList();
      if (list.isNotEmpty) map[group.name] = list;
    }
    return map;
  }

  /// All category names for the tab selector.
  List<String> get _categories {
    final cats = <String>[_kForYou];
    if (_favoriteStations.isNotEmpty) cats.add(_kFavorites);
    cats.addAll(_groupedStations.keys);
    return cats;
  }

  /// Stations for the currently selected category.
  List<Station> get _stationsForCategory {
    if (_selectedCategory == _kForYou) return _allStations;
    if (_selectedCategory == _kFavorites) return _favoriteStations;
    return _groupedStations[_selectedCategory] ?? [];
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onBack();
      },
      child: Focus(
        onKeyEvent: _onKeyEvent,
        child: ColoredBox(
          color: TvColors.background,
          child: SafeArea(
            child: TvPlatform.isDesktop ? _buildDesktopLayout() : _buildTvLayout(),
          ),
        ),
      ),
    );
  }

  /// Desktop: tabs + vertical grid.
  Widget _buildDesktopLayout() {
    final playing = _currentStation;
    final stations = _stationsForCategory;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Now Playing bar at top
        if (playing != null)
          _NowPlayingCard(station: playing, onTap: widget.onBack),
        // Category tabs
        _DesktopCategoryTabs(
          categories: _categories,
          selected: _selectedCategory,
          onSelected: (cat) => setState(() => _selectedCategory = cat),
        ),
        const SizedBox(height: TvSpacing.sm),
        // Station grid — vertical scrollable
        Expanded(
          child: stations.isEmpty
              ? Center(
                  child: Text(
                    'Nu sunt posturi în această categorie',
                    style: TvTypography.body,
                  ),
                )
              : Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: TvSpacing.marginHorizontal,
                  ),
                  child: GridView.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 200,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 160 / 216,
                    ),
                    itemCount: stations.length,
                    itemBuilder: (context, index) {
                      final station = stations[index];
                      final isPlaying = _currentStation?.id == station.id;
                      final isFavorite = _favoriteSlugs.contains(station.slug);
                      return TvStationCard(
                        station: station,
                        isPlaying: isPlaying,
                        isFavorite: isFavorite,
                        autofocus: index == 0,
                        onSelect: () => widget.onStationSelected(station),
                        onFavoriteToggle: () {},
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  /// TV: horizontal scrolling rows.
  Widget _buildTvLayout() {
    final playing = _currentStation;

    return CustomScrollView(
      slivers: [
        if (playing != null)
          SliverToBoxAdapter(
            child: _NowPlayingCard(station: playing, onTap: widget.onBack),
          ),
        if (_favoriteStations.isNotEmpty)
          SliverToBoxAdapter(
            child: TvStationRow(
              title: 'Favorite',
              stations: _favoriteStations,
              currentStation: _currentStation,
              favoriteSlugs: _favoriteSlugs,
              autofocusFirst: playing == null,
              onStationSelected: widget.onStationSelected,
            ),
          ),
        ..._groupedStations.entries.map((entry) {
          return SliverToBoxAdapter(
            child: TvStationRow(
              title: entry.key,
              stations: entry.value,
              currentStation: _currentStation,
              favoriteSlugs: _favoriteSlugs,
              onStationSelected: widget.onStationSelected,
            ),
          );
        }),
        const SliverToBoxAdapter(
          child: SizedBox(height: TvSpacing.xxl),
        ),
      ],
    );
  }
}

/// Desktop category tab selector — horizontal scrolling chips.
class _DesktopCategoryTabs extends StatelessWidget {
  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;

  const _DesktopCategoryTabs({
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: TvSpacing.marginHorizontal,
          vertical: 4,
        ),
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final cat = categories[index];
          final isActive = cat == selected;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => onSelected(cat),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: isActive ? TvColors.primary : TvColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  cat,
                  style: TvTypography.label.copyWith(
                    color: isActive ? Colors.white : TvColors.textSecondary,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Now Playing card — compact on desktop, bigger on TV.
class _NowPlayingCard extends StatelessWidget {
  final Station station;
  final VoidCallback onTap;

  const _NowPlayingCard({required this.station, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: TvSpacing.marginHorizontal,
        right: TvSpacing.marginHorizontal,
        top: TvSpacing.md,
        bottom: TvSpacing.sm,
      ),
      child: DesktopFocusable(
        autofocus: !TvPlatform.isDesktop,
        onSelect: onTap,
        builder: TvPlatform.isDesktop
            ? (context, isFocused, child) {
                // Desktop: subtle brightness change, no border
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    color: isFocused
                        ? TvColors.surfaceHigh
                        : TvColors.surface,
                    borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
                  ),
                  child: child,
                );
              }
            : FocusEffects.scaleWithBorder(
                scale: 1.02,
                borderColor: TvColors.primary,
                borderWidth: 2.5,
                borderRadius: BorderRadius.circular(TvSpacing.radiusLg),
              ),
        child: Container(
          padding: const EdgeInsets.all(TvSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
          ),
          child: Row(
            children: [
              // Artwork
              ClipRRect(
                borderRadius: BorderRadius.circular(TvSpacing.radiusSm),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: station.displayThumbnail(cacheWidth: 112),
                ),
              ),
              const SizedBox(width: TvSpacing.md),
              // Metadata
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.equalizer_rounded,
                            color: TvColors.primary, size: 16),
                        const SizedBox(width: TvSpacing.xs),
                        Text(
                          'Se redă acum',
                          style: TvTypography.caption.copyWith(
                            color: TvColors.primary,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: TvSpacing.sm),
                        Flexible(
                          child: Text(
                            station.title,
                            style: TvTypography.label.copyWith(
                              fontSize: 13,
                              color: TvColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          station.songTitle.isNotEmpty
                              ? station.songTitle
                              : station.title,
                          key: ValueKey('np-song-${station.songId}'),
                          style: TvTypography.title.copyWith(fontSize: 16),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (station.songArtist.isNotEmpty)
                      Text(
                        station.songArtist,
                        style: TvTypography.caption.copyWith(fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: TvColors.textTertiary, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}
