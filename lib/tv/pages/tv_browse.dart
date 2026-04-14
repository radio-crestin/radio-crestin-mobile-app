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
import '../tv_theme.dart';
import '../widgets/tv_station_row.dart';

/// Station list page (Browse).
///
/// Everything in one scrollable view:
/// - Now Playing card at top (big, focusable — select to return to station page)
/// - Station rows: Favorites → All → Categories
///
/// Focusing a card shows a preview (updates the focused station info).
/// Selecting a card plays that station + opens the station page.
/// BACK/ESC → returns to station page.
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
    final playing = _currentStation;

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
            child: CustomScrollView(
              slivers: [
                // === Now Playing card — big, prominent, focusable ===
                if (playing != null)
                  SliverToBoxAdapter(
                    child: _NowPlayingCard(
                      station: playing,
                      onTap: widget.onBack,
                    ),
                  ),
                // === Station rows ===
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
                SliverToBoxAdapter(
                  child: TvStationRow(
                    title: 'Alese pentru tine',
                    stations: _allStations,
                    currentStation: _currentStation,
                    favoriteSlugs: _favoriteSlugs,
                    autofocusFirst:
                        playing == null && _favoriteStations.isEmpty,
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
            ),
          ),
        ),
      ),
    );
  }
}

/// Big Now Playing card at the top of the browse page.
/// Shows artwork, station name, song, artist, listeners.
/// Focusable — select to return to station page.
class _NowPlayingCard extends StatelessWidget {
  final Station station;
  final VoidCallback onTap;

  const _NowPlayingCard({required this.station, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: TvSpacing.marginHorizontal,
        right: TvSpacing.marginHorizontal,
        top: TvSpacing.lg,
        bottom: TvSpacing.lg,
      ),
      child: DpadFocusable(
        autofocus: true,
        onSelect: onTap,
        builder: FocusEffects.scaleWithBorder(
          scale: 1.02,
          borderColor: TvColors.primary,
          borderWidth: 2.5,
          borderRadius: BorderRadius.circular(TvSpacing.radiusLg),
        ),
        child: Container(
          padding: const EdgeInsets.all(TvSpacing.md),
          decoration: BoxDecoration(
            color: TvColors.surface,
            borderRadius: BorderRadius.circular(TvSpacing.radiusLg),
          ),
          child: Row(
            children: [
              // Artwork
              ClipRRect(
                borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
                child: SizedBox(
                  width: 80,
                  height: 80,
                  child: station.displayThumbnail(cacheWidth: 160),
                ),
              ),
              const SizedBox(width: TvSpacing.lg),
              // Metadata
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // "Se redă acum" + station name
                    Row(
                      children: [
                        const Icon(Icons.equalizer_rounded,
                            color: TvColors.primary, size: 18),
                        const SizedBox(width: TvSpacing.sm),
                        Text(
                          'Se redă acum',
                          style: TvTypography.caption.copyWith(
                            color: TvColors.primary,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: TvSpacing.md),
                        Flexible(
                          child: Text(
                            station.title,
                            style: TvTypography.label.copyWith(
                              fontSize: 14,
                              color: TvColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: TvSpacing.xs),
                    // Song title — big
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          station.songTitle.isNotEmpty
                              ? station.songTitle
                              : station.title,
                          key: ValueKey('np-song-${station.songId}'),
                          style: TvTypography.headline.copyWith(fontSize: 20),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    // Artist
                    if (station.songArtist.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        station.songArtist,
                        style: TvTypography.body.copyWith(
                            fontSize: 14, color: TvColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: TvSpacing.md),
              // Listeners + arrow
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${station.totalListeners ?? 0}',
                    style: TvTypography.title.copyWith(
                      fontSize: 18,
                      color: TvColors.textPrimary,
                    ),
                  ),
                  Text('ascultători',
                      style: TvTypography.caption.copyWith(fontSize: 10)),
                ],
              ),
              const SizedBox(width: TvSpacing.md),
              const Icon(Icons.chevron_right_rounded,
                  color: TvColors.textTertiary, size: 28),
            ],
          ),
        ),
      ),
    );
  }
}
