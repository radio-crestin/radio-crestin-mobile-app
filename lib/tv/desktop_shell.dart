import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../appAudioHandler.dart';
import '../pages/SettingsPage.dart';
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
    final sorted = StationSortService.sort(
      stations: base,
      sortBy: _sortOption,
      playCounts: playCounts,
      favoriteSlugs: _favoriteSlugs,
    ).sorted;

    // Always surface favorites at the top, preserving their relative
    // order from the active sort. The "recommended" sort already weaves
    // favorites in, but the explicit bubble keeps them visually anchored
    // for any sort the user picks.
    if (_favoriteSlugs.isEmpty) return sorted;
    final favSet = _favoriteSlugs.toSet();
    final favs = <Station>[];
    final rest = <Station>[];
    for (final s in sorted) {
      (favSet.contains(s.slug) ? favs : rest).add(s);
    }
    return [...favs, ...rest];
  }

  void _playStation(Station station) {
    _audioHandler.playStation(station);
  }

  void _openNowPlaying() {
    if (_currentStation == null) return;
    final size = MediaQuery.of(context).size;
    final maxWidth = (size.width - 48).clamp(640.0, 1100.0);
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      barrierDismissible: true,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: size.height - 48,
          ),
          child: DesktopNowPlayingSheet(songHistory: widget.songHistory),
        ),
      ),
    );
  }

  Future<void> _openSearchDialog() async {
    final picked = await showDialog<Station>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (_) => _DesktopSearchDialog(
        stations: _allStations,
        currentStationId: _currentStation?.id,
        favoriteSlugs: _favoriteSlugs,
      ),
    );
    if (picked != null) {
      _playStation(picked);
    }
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

  Widget _navBtn({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip ?? '',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: active
                  ? TvColors.primary.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.06),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20,
                color: active ? TvColors.primary : TvColors.textSecondary),
          ),
        ),
      ),
    );
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final stations = _sortedStations;
    final station = _currentStation;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _openSearchDialog,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _openSearchDialog,
        const SingleActivator(LogicalKeyboardKey.slash): _openSearchDialog,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      backgroundColor: TvColors.background,
      body: Column(
        children: [
          // ── Top navbar ──
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: const BoxDecoration(
              color: TvColors.background,
              border: Border(
                bottom: BorderSide(color: TvColors.divider, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                // Logo + brand
                Image.asset('assets/icons/ic_logo_filled.png', width: 32, height: 32),
                const SizedBox(width: 10),
                const Text(
                  'Radio Crestin',
                  style: TextStyle(
                    color: TvColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.3,
                  ),
                ),
                const Spacer(),
                // Search
                _navBtn(
                  icon: Icons.search_rounded,
                  tooltip: 'Caută (Ctrl+K)',
                  onTap: _openSearchDialog,
                ),
                const SizedBox(width: 8),
                // Settings
                _navBtn(
                  icon: Icons.settings_outlined,
                  tooltip: 'Setări',
                  onTap: () => SettingsPage.show(context),
                ),
              ],
            ),
          ),

          // ── Sort selector + filter ──
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 4),
            child: SizedBox(
              height: 40,
              child: Row(
                children: [
                  // Sort dropdown
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
                  // Filter button
                  _navBtn(
                    icon: _selectedGroup != null
                        ? Icons.filter_alt_rounded
                        : Icons.filter_alt_outlined,
                    tooltip: _selectedGroup?.name ?? 'Filtrează',
                    active: _selectedGroup != null,
                    onTap: _showFilterOptions,
                  ),
                ],
              ),
            ),
          ),

          // ── Station grid ──
          Expanded(
            child: stations.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.radio_rounded,
                          size: 48,
                          color: TvColors.textTertiary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Nu sunt posturi disponibile',
                          style: TvTypography.body,
                        ),
                      ],
                    ),
                  )
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
                        final isFav = _favoriteSlugs.contains(s.slug);
                        return TvStationCard(
                          station: s,
                          isPlaying: _currentStation?.id == s.id,
                          isFavorite: isFav,
                          autofocus: i == 0,
                          onSelect: () => _playStation(s),
                          onFavoriteToggle: () =>
                              _stationDataService.setStationIsFavorite(
                                  s, !isFav),
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
            onPrevious: () => _audioHandler.skipToPrevious(),
            onNext: () => _audioHandler.skipToNext(),
          ),
        ],
      ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Mini player bar pinned to the bottom — matches mobile style
// ─────────────────────────────────────────────
class _DesktopMiniPlayer extends StatelessWidget {
  final Station station;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _DesktopMiniPlayer({
    required this.station,
    required this.isPlaying,
    required this.onTap,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
  });

  Widget _controlBtn({
    required IconData icon,
    required VoidCallback onTap,
    double size = 40,
    double iconSize = 22,
    Color? iconColor,
    Color? bg,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: bg ?? Colors.white.withValues(alpha: 0.08),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: iconColor ?? Colors.white, size: iconSize),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          // Allow vertical drag to open the full player
          onVerticalDragEnd: (details) {
            if (details.primaryVelocity != null && details.primaryVelocity! < -100) {
              onTap();
            }
          },
          child: Container(
            height: 80,
            decoration: BoxDecoration(
              color: TvColors.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 16,
                  spreadRadius: 1,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              children: [
                // Drag handle
                Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Content row
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
                    child: Row(
                      children: [
                        // Artwork
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 52,
                            height: 52,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              child: SizedBox(
                                key: ValueKey('mp-${station.artUri}'),
                                child: station.displayThumbnail(cacheWidth: 104),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        // Metadata: station name + song + artist
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // "Se redă acum" + station name
                              Row(
                                children: [
                                  const Icon(Icons.equalizer_rounded,
                                      color: TvColors.primary, size: 14),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Se redă acum',
                                    style: TvTypography.caption.copyWith(
                                      color: TvColors.primary,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 10,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      station.title,
                                      style: TvTypography.caption.copyWith(
                                        fontSize: 11,
                                        color: TvColors.textTertiary,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              // Song title
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 250),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    station.songTitle.isNotEmpty
                                        ? station.songTitle
                                        : station.title,
                                    key: ValueKey('mp-t-${station.songId}'),
                                    style: TvTypography.label.copyWith(
                                      fontSize: 14,
                                      color: TvColors.textPrimary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              // Artist
                              if (station.songArtist.isNotEmpty) ...[
                                const SizedBox(height: 1),
                                Text(
                                  station.songArtist,
                                  style: TvTypography.caption.copyWith(
                                    fontSize: 12,
                                    color: TvColors.textSecondary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Transport controls: prev | play/pause | next
                        _controlBtn(
                          icon: Icons.skip_previous_rounded,
                          iconColor: TvColors.textSecondary,
                          iconSize: 22,
                          size: 36,
                          onTap: onPrevious,
                        ),
                        const SizedBox(width: 8),
                        _controlBtn(
                          icon: isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          iconSize: 26,
                          size: 42,
                          bg: TvColors.primary,
                          onTap: onPlayPause,
                        ),
                        const SizedBox(width: 8),
                        _controlBtn(
                          icon: Icons.skip_next_rounded,
                          iconColor: TvColors.textSecondary,
                          iconSize: 22,
                          size: 36,
                          onTap: onNext,
                        ),
                      ],
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

// ─────────────────────────────────────────────
// Search dialog: focused text input + live filtered station list.
// ─────────────────────────────────────────────
class _DesktopSearchDialog extends StatefulWidget {
  final List<Station> stations;
  final int? currentStationId;
  final List<String> favoriteSlugs;

  const _DesktopSearchDialog({
    required this.stations,
    required this.currentStationId,
    required this.favoriteSlugs,
  });

  @override
  State<_DesktopSearchDialog> createState() => _DesktopSearchDialogState();
}

class _DesktopSearchDialogState extends State<_DesktopSearchDialog> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _query = '';
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<Station> get _results {
    if (_query.isEmpty) {
      // Show favorites + current station first when no query.
      final favs = widget.stations
          .where((s) => widget.favoriteSlugs.contains(s.slug))
          .toList();
      final rest =
          widget.stations.where((s) => !favs.contains(s)).toList();
      return [...favs, ...rest];
    }
    final q = _query.toLowerCase();
    return widget.stations.where((s) {
      return s.title.toLowerCase().contains(q) ||
          s.songTitle.toLowerCase().contains(q) ||
          s.songArtist.toLowerCase().contains(q);
    }).toList();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final results = _results;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown && results.isNotEmpty) {
      setState(() => _highlight = (_highlight + 1) % results.length);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp && results.isNotEmpty) {
      setState(
          () => _highlight = (_highlight - 1 + results.length) % results.length);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      if (results.isNotEmpty &&
          _highlight >= 0 &&
          _highlight < results.length) {
        Navigator.of(context).pop(results[_highlight]);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final size = MediaQuery.of(context).size;
    final dialogWidth = size.width.clamp(420.0, 720.0);
    final dialogMaxHeight = size.height * 0.7;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 60),
      child: Focus(
        onKeyEvent: _onKey,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: dialogWidth,
            maxHeight: dialogMaxHeight,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: TvColors.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 30,
                  spreadRadius: 4,
                ),
              ],
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.06),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Search input
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: TvColors.surfaceVariant,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      autofocus: true,
                      onChanged: (v) => setState(() {
                        _query = v;
                        _highlight = 0;
                      }),
                      onSubmitted: (_) {
                        if (results.isNotEmpty) {
                          Navigator.of(context).pop(results[_highlight.clamp(0, results.length - 1)]);
                        }
                      },
                      style: const TextStyle(
                          color: TvColors.textPrimary, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Caută o stație, melodie sau artist...',
                        hintStyle: TextStyle(
                          color: TvColors.textTertiary.withValues(alpha: 0.85),
                          fontSize: 15,
                        ),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: TvColors.textTertiary,
                          size: 22,
                        ),
                        suffixIcon: _query.isNotEmpty
                            ? MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: () {
                                    _controller.clear();
                                    setState(() {
                                      _query = '';
                                      _highlight = 0;
                                    });
                                    _focus.requestFocus();
                                  },
                                  child: const Padding(
                                    padding: EdgeInsets.only(right: 8),
                                    child: Icon(Icons.clear_rounded,
                                        color: TvColors.textTertiary,
                                        size: 20),
                                  ),
                                ),
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 14),
                      ),
                    ),
                  ),
                ),
                const Divider(
                    height: 1, thickness: 0.5, color: TvColors.divider),
                // Results
                Flexible(
                  child: results.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 40, horizontal: 24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.search_off_rounded,
                                  size: 36, color: TvColors.textTertiary),
                              const SizedBox(height: 10),
                              Text(
                                _query.isEmpty
                                    ? 'Nu sunt stații disponibile'
                                    : 'Nicio stație găsită pentru „$_query"',
                                style: TvTypography.body
                                    .copyWith(color: TvColors.textSecondary),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemCount: results.length,
                          itemBuilder: (_, i) {
                            final s = results[i];
                            return _SearchResultRow(
                              station: s,
                              highlighted: i == _highlight,
                              isCurrent: s.id == widget.currentStationId,
                              isFavorite:
                                  widget.favoriteSlugs.contains(s.slug),
                              onTap: () => Navigator.of(context).pop(s),
                              onHover: () => setState(() => _highlight = i),
                            );
                          },
                        ),
                ),
                // Footer with hints
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.18),
                    borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(16)),
                  ),
                  child: Row(
                    children: [
                      _kbdHint('↑↓', 'navighează'),
                      const SizedBox(width: 14),
                      _kbdHint('↵', 'redă'),
                      const Spacer(),
                      _kbdHint('Esc', 'închide'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _kbdHint(String key, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Text(
            key,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: TvColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TvTypography.caption
              .copyWith(fontSize: 11, color: TvColors.textTertiary),
        ),
      ],
    );
  }
}

class _SearchResultRow extends StatelessWidget {
  final Station station;
  final bool highlighted;
  final bool isCurrent;
  final bool isFavorite;
  final VoidCallback onTap;
  final VoidCallback onHover;

  const _SearchResultRow({
    required this.station,
    required this.highlighted,
    required this.isCurrent,
    required this.isFavorite,
    required this.onTap,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: highlighted
                ? TvColors.primary.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: highlighted
                  ? TvColors.primary.withValues(alpha: 0.4)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: station.displayThumbnail(cacheWidth: 88),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            station.title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: highlighted
                                  ? Colors.white
                                  : TvColors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isFavorite) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.favorite_rounded,
                              size: 14, color: TvColors.primary),
                        ],
                        if (isCurrent) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: TvColors.primary.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'SE REDĂ',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: TvColors.primary,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (station.songTitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          station.songArtist.isNotEmpty
                              ? '${station.songTitle}  ·  ${station.songArtist}'
                              : station.songTitle,
                          style: TvTypography.caption
                              .copyWith(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.play_arrow_rounded,
                size: 22,
                color: highlighted
                    ? TvColors.primary
                    : TvColors.textTertiary.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
