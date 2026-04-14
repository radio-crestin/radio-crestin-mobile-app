import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../appAudioHandler.dart';
import '../queries/getStations.graphql.dart';
import '../services/station_data_service.dart';
import '../services/station_sort_service.dart';
import '../services/play_count_service.dart';
import '../types/Station.dart';
import 'tv_shell.dart';
import 'tv_theme.dart';
import 'widgets/tv_station_card.dart';
import 'desktop_now_playing_sheet.dart';

/// Desktop shell: browse grid always visible, mini player pinned at bottom.
/// Tapping the mini player opens a draggable now-playing sheet (~80% height).
class DesktopShell extends StatefulWidget {
  final List<TvSongEntry> songHistory;

  const DesktopShell({super.key, required this.songHistory});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];

  Station? _currentStation;
  List<Station> _allStations = [];
  List<String> _favoriteSlugs = [];
  List<Query$GetStations$station_groups> _groups = [];
  bool _isPlaying = false;

  StationSortOption _sortOption = StationSortOption.recommended;
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

    _subscriptions.add(
      _audioHandler.playbackState.stream.listen((state) {
        if (mounted) setState(() => _isPlaying = state.playing);
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
    return StationSortService.sort(
      stations: base,
      sortBy: _sortOption,
      playCounts: playCounts,
      favoriteSlugs: _favoriteSlugs,
    ).sorted;
  }

  void _playStation(Station station) {
    _audioHandler.playStation(station);
  }

  void _openNowPlaying() {
    if (_currentStation == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.82,
        child: DesktopNowPlayingSheet(songHistory: widget.songHistory),
      ),
    );
  }

  // ─── Sort / Filter bottom sheets ───

  void _showSortOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: TvColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dragHandle(),
              ...StationSortOption.values.map((opt) {
                final sel = opt == _sortOption;
                return ListTile(
                  leading: Icon(
                    StationSortLabels.icons[opt],
                    size: 20,
                    color: opt == StationSortOption.recommended
                        ? const Color(0xFFF59E0B)
                        : sel ? TvColors.primary : TvColors.textSecondary,
                  ),
                  title: Text(
                    StationSortLabels.labels[opt] ?? '',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                      color: sel ? TvColors.primary : TvColors.textPrimary,
                    ),
                  ),
                  trailing: sel
                      ? const Icon(Icons.check_rounded, size: 20, color: TvColors.primary)
                      : null,
                  onTap: () {
                    setState(() => _sortOption = opt);
                    StationSortService.saveSortOption(opt);
                    _stationDataService.invalidateSortCache();
                    Navigator.pop(ctx);
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  void _showFilterOptions() {
    final sorted = List<Query$GetStations$station_groups>.from(_groups)
      ..sort((a, b) => a.order.compareTo(b.order));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: TvColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, sc) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 6),
              child: _dragHandle(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Filtrează stații',
                    style: TvTypography.title.copyWith(fontWeight: FontWeight.w700, fontSize: 20)),
              ),
            ),
            const Divider(height: 1, thickness: 0.5, color: TvColors.divider),
            Expanded(
              child: ListView(
                controller: sc,
                padding: const EdgeInsets.only(top: 4, bottom: 24),
                children: [
                  _filterTile(
                    icon: Icons.radio_rounded,
                    label: 'Toate stațiile radio',
                    selected: _selectedGroup == null,
                    onTap: () {
                      setState(() => _selectedGroup = null);
                      Navigator.pop(ctx);
                    },
                  ),
                  ...sorted.map((g) => _filterTile(
                        icon: Icons.folder_rounded,
                        label: g.name,
                        selected: _selectedGroup?.id == g.id,
                        onTap: () {
                          setState(() => _selectedGroup = g);
                          Navigator.pop(ctx);
                        },
                      )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dragHandle() => Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
      );

  ListTile _filterTile({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, size: 20, color: selected ? TvColors.primary : TvColors.textSecondary),
      title: Text(label,
          style: TextStyle(
              fontSize: 15,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? TvColors.primary : TvColors.textPrimary)),
      trailing:
          selected ? const Icon(Icons.check_rounded, size: 20, color: TvColors.primary) : null,
      onTap: onTap,
    );
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final stations = _sortedStations;
    final station = _currentStation;

    return Scaffold(
      backgroundColor: TvColors.background,
      body: Column(
        children: [
          // ── Sort selector + filter ──
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  Expanded(
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: _showSortOptions,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(StationSortLabels.icons[_sortOption],
                                size: 18,
                                color: _sortOption == StationSortOption.recommended
                                    ? const Color(0xFFF59E0B)
                                    : TvColors.textPrimary),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                StationSortLabels.labels[_sortOption] ?? '',
                                style: TvTypography.title
                                    .copyWith(fontSize: 17, fontWeight: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.keyboard_arrow_down_rounded,
                                size: 20, color: TvColors.textTertiary),
                          ],
                        ),
                      ),
                    ),
                  ),
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

          // ── Station grid ──
          Expanded(
            child: stations.isEmpty
                ? Center(child: Text('Nu sunt posturi', style: TvTypography.body))
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: GridView.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 200,
                        crossAxisSpacing: 12,
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
                          onSelect: () => _playStation(s),
                          onFavoriteToggle: () {},
                        );
                      },
                    ),
                  ),
          ),

          // ── Bottom mini player ──
          if (station != null) _DesktopMiniPlayer(
            station: station,
            isPlaying: _isPlaying,
            onTap: _openNowPlaying,
            onPlayPause: () => _isPlaying ? _audioHandler.pause() : _audioHandler.play(),
            onNext: () => _audioHandler.skipToNext(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Mini player bar pinned to the bottom
// ─────────────────────────────────────────────
class _DesktopMiniPlayer extends StatelessWidget {
  final Station station;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;

  const _DesktopMiniPlayer({
    required this.station,
    required this.isPlaying,
    required this.onTap,
    required this.onPlayPause,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 72,
          decoration: const BoxDecoration(
            color: TvColors.surface,
            border: Border(top: BorderSide(color: TvColors.divider, width: 0.5)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              // Artwork
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: SizedBox(
                      key: ValueKey('mp-${station.artUri}'),
                      child: station.displayThumbnail(cacheWidth: 96),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              // Metadata
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          station.songTitle.isNotEmpty ? station.songTitle : station.title,
                          key: ValueKey('mp-t-${station.songId}'),
                          style: TvTypography.label.copyWith(
                              fontSize: 14, color: TvColors.textPrimary, fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      station.songArtist.isNotEmpty ? station.songArtist : station.title,
                      style: TvTypography.caption.copyWith(fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Play / Pause
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onPlayPause,
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      key: ValueKey('mp-pp-$isPlaying'),
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Next
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onNext,
                  behavior: HitTestBehavior.opaque,
                  child: const Icon(Icons.skip_next_rounded, color: TvColors.textSecondary, size: 28),
                ),
              ),
              const SizedBox(width: 8),
              // Expand chevron
              const Icon(Icons.keyboard_arrow_up_rounded, color: TvColors.textTertiary, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}
