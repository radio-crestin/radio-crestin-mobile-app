import 'dart:async';

import 'package:dpad/dpad.dart';
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

/// TV-only browse page.
///
/// Shows the "For You" sort selector + filter at top, then a grid of stations.
/// ESC / Back → returns to the now-playing page (never exits the app).
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

  StationSortOption _sortOption = StationSortOption.recommended;

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();
    _sortOption = StationSortService.loadSavedSort();

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
      sortBy: _sortOption,
      playCounts: playCounts,
      favoriteSlugs: _favoriteSlugs,
    ).sorted;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // ESC / Back → go back to now-playing, never exit the app
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
    final stations = _sortedStations;

    return PopScope(
      // Block system back — we handle it ourselves
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onBack();
      },
      child: Focus(
        onKeyEvent: _onKeyEvent,
        child: ColoredBox(
          color: TvColors.background,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Now-playing card at top
                if (playing != null)
                  _TvNowPlayingCard(station: playing, onTap: widget.onBack),

                // Sort + Filter header
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: TvSpacing.marginHorizontal,
                    vertical: TvSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        StationSortLabels.icons[_sortOption],
                        size: 20,
                        color: _sortOption == StationSortOption.recommended
                            ? const Color(0xFFF59E0B)
                            : TvColors.textPrimary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          StationSortLabels.labels[_sortOption] ?? '',
                          style: TvTypography.headline.copyWith(fontSize: 20),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),

                // Station grid
                Expanded(
                  child: stations.isEmpty
                      ? Center(
                          child: Text('Nu sunt posturi', style: TvTypography.body),
                        )
                      : Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: TvSpacing.marginHorizontal,
                          ),
                          child: GridView.builder(
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 220,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 12,
                              childAspectRatio: 160 / 216,
                            ),
                            itemCount: stations.length,
                            itemBuilder: (_, i) {
                              final s = stations[i];
                              return TvStationCard(
                                station: s,
                                isPlaying: _currentStation?.id == s.id,
                                isFavorite: _favoriteSlugs.contains(s.slug),
                                autofocus: i == 0,
                                onSelect: () => widget.onStationSelected(s),
                                onFavoriteToggle: () {},
                              );
                            },
                          ),
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

/// Compact now-playing card at top of the TV browse page.
class _TvNowPlayingCard extends StatelessWidget {
  final Station station;
  final VoidCallback onTap;

  const _TvNowPlayingCard({required this.station, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: TvSpacing.marginHorizontal,
        right: TvSpacing.marginHorizontal,
        top: TvSpacing.lg,
        bottom: TvSpacing.sm,
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
              ClipRRect(
                borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
                child: SizedBox(
                  width: 80,
                  height: 80,
                  child: station.displayThumbnail(cacheWidth: 160),
                ),
              ),
              const SizedBox(width: TvSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          station.songTitle.isNotEmpty
                              ? station.songTitle
                              : station.title,
                          key: ValueKey('np-${station.songId}'),
                          style: TvTypography.headline.copyWith(fontSize: 20),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
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
              const Icon(Icons.chevron_right_rounded,
                  color: TvColors.textTertiary, size: 28),
            ],
          ),
        ),
      ),
    );
  }
}
