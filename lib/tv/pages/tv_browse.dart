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
import '../widgets/desktop_focusable.dart';
import '../widgets/tv_station_row.dart';

/// TV homepage — Android TV–style "rails" layout.
///
/// Header bar with brand mark + settings gear, a hero "Now Playing"
/// card when something is playing, then a vertical list of horizontal
/// rails (Favorites, Pentru tine, Cele mai ascultate, Toate stațiile).
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
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  // ─── Rail content ───────────────────────────────────────────────

  List<Station> _sortedBy(StationSortOption opt) {
    final playCounts = GetIt.instance<PlayCountService>().playCounts;
    return StationSortService.sort(
      stations: List<Station>.from(_allStations),
      sortBy: opt,
      playCounts: playCounts,
      favoriteSlugs: _favoriteSlugs,
    ).sorted;
  }

  List<Station> get _favorites {
    final favSet = _favoriteSlugs.toSet();
    return _allStations.where((s) => favSet.contains(s.slug)).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  List<Station> get _mostPlayed {
    final counts = GetIt.instance<PlayCountService>().playCounts;
    if (counts.isEmpty) return const [];
    final playedSlugs = counts.entries.where((e) => e.value > 0).map((e) => e.key).toSet();
    if (playedSlugs.isEmpty) return const [];
    final sorted = _sortedBy(StationSortOption.mostPlayed);
    return sorted.where((s) => playedSlugs.contains(s.slug)).toList();
  }

  // ─── Actions ────────────────────────────────────────────────────

  void _openNowPlaying() => widget.onBack();

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

  // ─── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onKeyEvent,
      child: ColoredBox(
        color: TvColors.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Header(),
            Expanded(child: _buildRails()),
          ],
        ),
      ),
    );
  }

  Widget _buildRails() {
    if (_allStations.isEmpty) {
      return Center(
        child: Text('Nu sunt posturi', style: TvTypography.body),
      );
    }

    final favorites = _favorites;
    final recommendations = _sortedBy(StationSortOption.recommended);
    final mostPlayed = _mostPlayed;
    final alphabetical = _sortedBy(StationSortOption.alphabetical);

    final hero = _currentStation;
    final rails = <Widget>[];
    bool grabbedAutofocus = false;

    if (hero != null) {
      rails.add(_NowPlayingHero(
        station: hero,
        autofocus: !grabbedAutofocus,
        onTap: _openNowPlaying,
      ));
      grabbedAutofocus = true;
    }

    void addRail(String title, List<Station> stations) {
      if (stations.isEmpty) return;
      rails.add(TvStationRow(
        title: title,
        stations: stations,
        currentStation: _currentStation,
        favoriteSlugs: _favoriteSlugs,
        autofocusFirst: !grabbedAutofocus,
        onStationSelected: widget.onStationSelected,
      ));
      grabbedAutofocus = true;
    }

    addRail('Favoritele tale', favorites);
    addRail('Pentru tine', recommendations);
    addRail('Cele mai ascultate', mostPlayed);
    addRail('Toate stațiile', alphabetical);

    return ListView(
      // Clip.none lets the focused card's outer glow render past the
      // viewport edges instead of being sliced off mid-rail.
      clipBehavior: Clip.none,
      padding: const EdgeInsets.only(top: TvSpacing.sm, bottom: TvSpacing.lg),
      children: rails,
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

// ─────────────────────────────────────────────────────────────────────
// Now Playing hero card.
// ─────────────────────────────────────────────────────────────────────
class _NowPlayingHero extends StatelessWidget {
  final Station station;
  final bool autofocus;
  final VoidCallback onTap;

  const _NowPlayingHero({
    required this.station,
    required this.autofocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        TvSpacing.marginHorizontal,
        TvSpacing.sm,
        TvSpacing.marginHorizontal,
        TvSpacing.lg,
      ),
      child: DesktopFocusable(
        autofocus: autofocus,
        onSelect: onTap,
        builder: FocusEffects.scaleWithBorder(
          scale: 1.02,
          borderColor: TvColors.primary,
          borderWidth: 3,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Container(
          height: 160,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                TvColors.primary.withValues(alpha: 0.18),
                TvColors.surface,
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.06),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.all(TvSpacing.md),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 128,
                  height: 128,
                  child: station.displayThumbnail(cacheWidth: 256),
                ),
              ),
              const SizedBox(width: TvSpacing.lg),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.equalizer_rounded,
                            color: TvColors.primary, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          'SE REDĂ ACUM',
                          style: TvTypography.caption.copyWith(
                            color: TvColors.primary,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      station.title,
                      style: TvTypography.headline
                          .copyWith(fontSize: 26, fontWeight: FontWeight.w800),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (station.songTitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        station.songArtist.isNotEmpty
                            ? '${station.songTitle}  ·  ${station.songArtist}'
                            : station.songTitle,
                        style: TvTypography.body.copyWith(
                          fontSize: 15,
                          color: TvColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
