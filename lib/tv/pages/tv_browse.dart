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
    final stations = _sortedStations;

    // Note: BACK handling is owned by the parent TvHome, since TvBrowse
    // is one of several IndexedStack children — having a PopScope here
    // would intercept BACK even when this page is hidden.
    return Focus(
        onKeyEvent: _onKeyEvent,
        child: ColoredBox(
          color: TvColors.background,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Sort header pinned in a fixed-height band that matches the
                // rail's brand mark, so the logo and the category selector
                // share the same baseline regardless of playback state.
                SizedBox(
                  height: TvHeaderBar.height,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: TvSpacing.marginHorizontal,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          StationSortLabels.icons[_sortOption],
                          size: 22,
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
                              crossAxisSpacing: 8,
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
                                // No top-level navigation any more — the
                                // first card is the entry point and grabs
                                // focus on cold launch.
                                region: 'content',
                                isEntryPoint: i == 0,
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
    );
  }
}
