import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../appAudioHandler.dart';
import '../services/station_data_service.dart';
import '../types/Station.dart';
import 'tv_shell.dart';
import 'tv_theme.dart';

/// Full now-playing panel shown as a bottom sheet (~80 % of the screen).
/// Tap outside or drag down to dismiss.
class DesktopNowPlayingSheet extends StatefulWidget {
  final List<TvSongEntry> songHistory;

  const DesktopNowPlayingSheet({super.key, required this.songHistory});

  @override
  State<DesktopNowPlayingSheet> createState() => _DesktopNowPlayingSheetState();
}

class _DesktopNowPlayingSheetState extends State<DesktopNowPlayingSheet> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];

  Station? _station;
  List<String> _favoriteSlugs = [];
  bool _isPlaying = false;
  bool _liked = false;
  bool _disliked = false;
  int _lastSongId = -1;

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();

    _subscriptions.add(
      Rx.combineLatest2(
        _audioHandler.currentStation.stream,
        _stationDataService.favoriteStationSlugs.stream,
        (Station? s, List<String> f) => (s, f),
      ).listen((d) {
        if (!mounted) return;
        final s = d.$1;
        setState(() {
          _station = s;
          _favoriteSlugs = d.$2;
        });
        if (s != null && s.songId != _lastSongId) {
          _lastSongId = s.songId;
          _liked = false;
          _disliked = false;
        }
      }),
    );

    _subscriptions.add(
      _audioHandler.playbackState.stream.listen((s) {
        if (mounted) setState(() => _isPlaying = s.playing);
      }),
    );
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  bool get _isFavorite => _station != null && _favoriteSlugs.contains(_station!.slug);

  List<TvSongEntry> get _prevSongs =>
      widget.songHistory.length > 1 ? widget.songHistory.sublist(1) : [];

  Widget _circleBtn({
    required IconData icon,
    required VoidCallback onTap,
    Color? color,
    double size = 44,
    double iconSize = 22,
    Color? bg,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: bg ?? TvColors.surfaceVariant.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color ?? TvColors.textSecondary, size: iconSize),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final station = _station;
    if (station == null) {
      return Container(
        decoration: const BoxDecoration(
          color: TvColors.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: const Center(child: CircularProgressIndicator(color: TvColors.primary)),
      );
    }

    final prevSongs = _prevSongs;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Blurred background
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            child: SizedBox.expand(
              key: ValueKey('dbg-${station.id}-${station.artUri}'),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                child: ColorFiltered(
                  colorFilter:
                      ColorFilter.mode(Colors.black.withValues(alpha: 0.7), BlendMode.darken),
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: 200,
                      height: 200,
                      child: station.displayThumbnail(cacheWidth: 400),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Content
          SafeArea(
            child: Column(
              children: [
                // Drag handle + close
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
                  child: Row(
                    children: [
                      const Spacer(),
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white30,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const Spacer(),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.close_rounded, color: TvColors.textTertiary, size: 22),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Main content
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Row(
                      children: [
                        // Artwork
                        Expanded(
                          flex: 4,
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 380, maxHeight: 380),
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 400),
                                  child: Container(
                                    key: ValueKey('dart-${station.artUri}'),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.5),
                                          blurRadius: 40,
                                          spreadRadius: 5,
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: station.displayThumbnail(cacheWidth: 600),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 32),

                        // Right side: metadata + songs + controls
                        Expanded(
                          flex: 5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // Favorite button row
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      station.title,
                                      style: TvTypography.body
                                          .copyWith(color: TvColors.textSecondary, fontSize: 15),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  _circleBtn(
                                    icon: _isFavorite
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    size: 36,
                                    iconSize: 20,
                                    color: _isFavorite ? TvColors.primary : Colors.white70,
                                    bg: Colors.white.withValues(alpha: 0.08),
                                    onTap: () => _audioHandler.customAction('toggleFavorite'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),

                              // Song title
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 250),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    station.songTitle.isNotEmpty ? station.songTitle : 'Live Radio',
                                    key: ValueKey('ds-${station.songId}'),
                                    style: TvTypography.displayMedium.copyWith(fontSize: 26),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              if (station.songArtist.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 250),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      station.songArtist,
                                      key: ValueKey('da-${station.songId}'),
                                      style: TvTypography.title
                                          .copyWith(color: TvColors.textSecondary, fontSize: 16),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(Icons.headphones_rounded,
                                      size: 14, color: TvColors.textTertiary),
                                  const SizedBox(width: 4),
                                  Text('${station.totalListeners ?? 0} ascultători',
                                      style: TvTypography.caption.copyWith(fontSize: 12)),
                                ],
                              ),

                              // Recent songs — no title, just a subtle list
                              if (prevSongs.isNotEmpty) ...[
                                const SizedBox(height: 20),
                                const Divider(height: 1, thickness: 0.3, color: TvColors.divider),
                                const SizedBox(height: 12),
                                ...List.generate(
                                  prevSongs.length.clamp(0, 4),
                                  (i) => _SongRow(entry: prevSongs[i]),
                                ),
                              ],

                              const SizedBox(height: 24),

                              // Controls
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _circleBtn(
                                    icon: _liked
                                        ? Icons.thumb_up_alt_rounded
                                        : Icons.thumb_up_alt_outlined,
                                    iconSize: 18,
                                    size: 42,
                                    color: _liked ? TvColors.primary : null,
                                    onTap: () {
                                      setState(() {
                                        _liked = !_liked;
                                        if (_liked) _disliked = false;
                                      });
                                      _audioHandler.customAction('likeSong');
                                    },
                                  ),
                                  const SizedBox(width: 14),
                                  _circleBtn(
                                    icon: Icons.skip_previous_rounded,
                                    color: TvColors.textPrimary,
                                    iconSize: 26,
                                    size: 48,
                                    onTap: () => _audioHandler.skipToPrevious(),
                                  ),
                                  const SizedBox(width: 14),
                                  // Play / Pause
                                  MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    child: GestureDetector(
                                      onTap: () =>
                                          _isPlaying ? _audioHandler.pause() : _audioHandler.play(),
                                      child: AnimatedScale(
                                        scale: 1.0,
                                        duration: const Duration(milliseconds: 150),
                                        child: Container(
                                          width: 60,
                                          height: 60,
                                          decoration: const BoxDecoration(
                                            color: TvColors.primary,
                                            shape: BoxShape.circle,
                                          ),
                                          child: AnimatedSwitcher(
                                            duration: const Duration(milliseconds: 150),
                                            child: Icon(
                                              _isPlaying
                                                  ? Icons.pause_rounded
                                                  : Icons.play_arrow_rounded,
                                              key: ValueKey('dpp-$_isPlaying'),
                                              color: Colors.white,
                                              size: 34,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  _circleBtn(
                                    icon: Icons.skip_next_rounded,
                                    color: TvColors.textPrimary,
                                    iconSize: 26,
                                    size: 48,
                                    onTap: () => _audioHandler.skipToNext(),
                                  ),
                                  const SizedBox(width: 14),
                                  _circleBtn(
                                    icon: _disliked
                                        ? Icons.thumb_down_alt_rounded
                                        : Icons.thumb_down_alt_outlined,
                                    iconSize: 18,
                                    size: 42,
                                    color: _disliked ? TvColors.primary : null,
                                    onTap: () {
                                      setState(() {
                                        _disliked = !_disliked;
                                        if (_disliked) _liked = false;
                                      });
                                      _audioHandler.customAction('dislikeSong');
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Minimal song row — no section title, just icon + text + time.
class _SongRow extends StatelessWidget {
  final TvSongEntry entry;
  const _SongRow({required this.entry});

  String get _timeAgo {
    final d = DateTime.now().difference(entry.timestamp);
    if (d.inSeconds < 30) return 'acum';
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}z';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(Icons.music_note_rounded, size: 14, color: TvColors.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.artist.isNotEmpty ? '${entry.title}  ·  ${entry.artist}' : entry.title,
              style: TvTypography.caption.copyWith(fontSize: 12, color: TvColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(_timeAgo, style: TvTypography.caption.copyWith(fontSize: 11, color: TvColors.textTertiary)),
        ],
      ),
    );
  }
}
