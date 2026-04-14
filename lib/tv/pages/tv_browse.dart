import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../queries/getStations.graphql.dart';
import '../../services/station_data_service.dart';
import '../../services/station_sort_service.dart';
import '../../services/play_count_service.dart';
import '../../types/Station.dart';
import '../tv_platform.dart';
import '../tv_theme.dart';
import '../widgets/desktop_focusable.dart';
import '../widgets/tv_station_card.dart';
import '../widgets/tv_station_row.dart';

/// Station list page (Browse).
///
/// On Android TV: horizontal rows (Favorites → Categories).
/// On Desktop: "Pentru tine" dropdown + filter button (same as mobile), vertical grid.
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

  /// Sort option — mirrors mobile app's sort selector.
  StationSortOption _sortOption = StationSortOption.recommended;

  /// Selected filter group — null means "all stations".
  Query$GetStations$station_groups? _selectedGroup;

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();
    _sortOption = StationSortService.loadSavedSort();

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

  /// Stations for desktop grid — filtered by group, sorted by sort option.
  List<Station> get _desktopStations {
    List<Station> base;
    if (_selectedGroup != null) {
      final ids = _selectedGroup!.station_to_station_groups
          .map((e) => e.station_id)
          .toSet();
      base = _allStations.where((s) => ids.contains(s.id)).toList();
    } else {
      base = List<Station>.from(_allStations);
    }

    final playCounts = GetIt.instance<PlayCountService>().playCounts;
    final result = StationSortService.sort(
      stations: base,
      sortBy: _sortOption,
      playCounts: playCounts,
      favoriteSlugs: _favoriteSlugs,
    );
    return result.sorted;
  }

  void _showSortOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: TvColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ...StationSortOption.values.map((option) {
                  final isSelected = option == _sortOption;
                  return ListTile(
                    leading: Icon(
                      StationSortLabels.icons[option],
                      size: 20,
                      color: option == StationSortOption.recommended
                          ? const Color(0xFFF59E0B)
                          : isSelected
                              ? TvColors.primary
                              : TvColors.textSecondary,
                    ),
                    title: Text(
                      StationSortLabels.labels[option] ?? '',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                        color: isSelected
                            ? TvColors.primary
                            : TvColors.textPrimary,
                      ),
                    ),
                    trailing: isSelected
                        ? const Icon(Icons.check_rounded,
                            size: 20, color: TvColors.primary)
                        : null,
                    onTap: () {
                      setState(() => _sortOption = option);
                      StationSortService.saveSortOption(option);
                      _stationDataService.invalidateSortCache();
                      Navigator.pop(context);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFilterOptions() {
    final sortedGroups = List<Query$GetStations$station_groups>.from(_groups)
      ..sort((a, b) => a.order.compareTo(b.order));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: TvColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Filtrează stații',
                      style: TvTypography.title.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1, thickness: 0.5, color: TvColors.divider),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.only(top: 4, bottom: 24),
                    children: [
                      // "All stations" option
                      ListTile(
                        leading: Icon(
                          Icons.radio_rounded,
                          size: 20,
                          color: _selectedGroup == null
                              ? TvColors.primary
                              : TvColors.textSecondary,
                        ),
                        title: Text(
                          'Toate stațiile radio',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: _selectedGroup == null
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: _selectedGroup == null
                                ? TvColors.primary
                                : TvColors.textPrimary,
                          ),
                        ),
                        trailing: _selectedGroup == null
                            ? const Icon(Icons.check_rounded,
                                size: 20, color: TvColors.primary)
                            : null,
                        onTap: () {
                          setState(() => _selectedGroup = null);
                          Navigator.pop(context);
                        },
                      ),
                      ...sortedGroups.map((group) {
                        final isSelected = _selectedGroup?.id == group.id;
                        return ListTile(
                          leading: Icon(
                            Icons.folder_rounded,
                            size: 20,
                            color: isSelected
                                ? TvColors.primary
                                : TvColors.textSecondary,
                          ),
                          title: Text(
                            group.name,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight:
                                  isSelected ? FontWeight.w600 : FontWeight.w400,
                              color: isSelected
                                  ? TvColors.primary
                                  : TvColors.textPrimary,
                            ),
                          ),
                          trailing: isSelected
                              ? const Icon(Icons.check_rounded,
                                  size: 20, color: TvColors.primary)
                              : null,
                          onTap: () {
                            setState(() => _selectedGroup = group);
                            Navigator.pop(context);
                          },
                        );
                      }),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
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
            child: TvPlatform.isDesktop
                ? _buildDesktopLayout()
                : _buildTvLayout(),
          ),
        ),
      ),
    );
  }

  /// Desktop: sort dropdown + filter button + vertical grid.
  Widget _buildDesktopLayout() {
    final playing = _currentStation;
    final stations = _desktopStations;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Now Playing bar
        if (playing != null)
          _NowPlayingCard(station: playing, onTap: widget.onBack),
        // Sort selector + filter button (matches mobile app)
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: TvSpacing.marginHorizontal,
            vertical: TvSpacing.sm,
          ),
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                // Sort selector: icon + label + chevron
                Expanded(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: _showSortOptions,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            StationSortLabels.icons[_sortOption],
                            size: 18,
                            color: _sortOption == StationSortOption.recommended
                                ? const Color(0xFFF59E0B)
                                : TvColors.textPrimary,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              StationSortLabels.labels[_sortOption] ?? '',
                              style: TvTypography.title.copyWith(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 20,
                            color: TvColors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Filter button
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: _showFilterOptions,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _selectedGroup != null
                            ? TvColors.primary.withValues(alpha: 0.12)
                            : Colors.white.withValues(alpha: 0.07),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _selectedGroup != null
                            ? Icons.filter_alt_rounded
                            : Icons.filter_alt_outlined,
                        size: 22,
                        color: _selectedGroup != null
                            ? TvColors.primary
                            : TvColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Station grid
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
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 200,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 160 / 216,
                    ),
                    itemCount: stations.length,
                    itemBuilder: (context, index) {
                      final station = stations[index];
                      final isPlaying = _currentStation?.id == station.id;
                      final isFavorite =
                          _favoriteSlugs.contains(station.slug);
                      return TvStationCard(
                        station: station,
                        isPlaying: isPlaying,
                        isFavorite: isFavorite,
                        autofocus: index == 0,
                        onSelect: () =>
                            widget.onStationSelected(station),
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
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    color: isFocused ? TvColors.surfaceHigh : TvColors.surface,
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
              ClipRRect(
                borderRadius: BorderRadius.circular(TvSpacing.radiusSm),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: station.displayThumbnail(cacheWidth: 112),
                ),
              ),
              const SizedBox(width: TvSpacing.md),
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
