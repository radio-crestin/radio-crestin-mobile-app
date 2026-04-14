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

/// Full now-playing panel shown as a bottom sheet (~82% of screen).
/// Matches the mobile FullAudioPlayer pattern: gradient background,
/// centered artwork, song info, transport controls, song history.
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

  Widget _roundBtn({
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
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: bg ?? Colors.white.withValues(alpha: 0.1),
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: const Center(child: CircularProgressIndicator(color: TvColors.primary)),
      );
    }

    final prevSongs = _prevSongs;
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    // Responsive artwork size (like mobile FullAudioPlayer)
    final panelHeight = screenHeight * 0.82;
    final fixedBudget = 380.0;
    final maxThumbWidth = screenWidth * 0.35;
    final thumbSize = (panelHeight - fixedBudget).clamp(160.0, 320.0).clamp(160.0, maxThumbWidth);

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Blurred artwork + dark gradient (like mobile)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            child: SizedBox.expand(
              key: ValueKey('dbg-${station.id}-${station.artUri}'),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                child: ColorFiltered(
                  colorFilter:
                      ColorFilter.mode(Colors.black.withValues(alpha: 0.65), BlendMode.darken),
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
          // Gradient overlay (matches mobile dark theme gradient)
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF2C1018).withValues(alpha: 0.8),
                  const Color(0xFF1A0A0F).withValues(alpha: 0.6),
                  TvColors.background.withValues(alpha: 0.95),
                ],
                stops: const [0.0, 0.35, 0.75],
              ),
            ),
          ),

          // Content
          SafeArea(
            child: Column(
              children: [
                // Drag handle
                Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10),
                  decoration: BoxDecoration(
                    color: Colors.white30,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                // Station title (like mobile full player top)
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    station.title,
                    key: ValueKey('fp-title-${station.id}'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: TvColors.textPrimary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const Spacer(flex: 1),
                // Main content: artwork left + metadata right
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Artwork
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        child: Container(
                          key: ValueKey('fp-art-${station.artUri}'),
                          width: thumbSize,
                          height: thumbSize,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.5),
                                blurRadius: 30,
                                spreadRadius: 3,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: station.displayThumbnail(cacheWidth: (thumbSize * 2).toInt()),
                          ),
                        ),
                      ),
                      const SizedBox(width: 36),
                      // Right side: metadata + songs + controls
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Song title
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  station.songTitle.isNotEmpty ? station.songTitle : 'Live Radio',
                                  key: ValueKey('fp-s-${station.songId}'),
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w600,
                                    color: TvColors.textPrimary,
                                    height: 1.2,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            if (station.songArtist.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 250),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    station.songArtist,
                                    key: ValueKey('fp-a-${station.songId}'),
                                    style: const TextStyle(
                                      fontSize: 15,
                                      color: TvColors.textSecondary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                const Icon(Icons.headphones_rounded,
                                    size: 14, color: TvColors.textTertiary),
                                const SizedBox(width: 4),
                                Text('${station.totalListeners ?? 0} ascultători',
                                    style: TvTypography.caption.copyWith(fontSize: 12)),
                              ],
                            ),

                            // Song history — compact, no title
                            if (prevSongs.isNotEmpty) ...[
                              const SizedBox(height: 18),
                              const Divider(height: 1, thickness: 0.3, color: TvColors.divider),
                              const SizedBox(height: 10),
                              ...List.generate(
                                prevSongs.length.clamp(0, 4),
                                (i) => _SongRow(entry: prevSongs[i]),
                              ),
                            ],

                            const SizedBox(height: 24),

                            // Action chips: like / dislike / favorite
                            Row(
                              children: [
                                _chip(
                                  icon: _liked ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined,
                                  label: 'Îmi place',
                                  active: _liked,
                                  onTap: () {
                                    setState(() { _liked = !_liked; if (_liked) _disliked = false; });
                                    _audioHandler.customAction('likeSong');
                                  },
                                ),
                                const SizedBox(width: 10),
                                _chip(
                                  icon: _disliked ? Icons.thumb_down_alt_rounded : Icons.thumb_down_alt_outlined,
                                  label: 'Nu-mi place',
                                  active: _disliked,
                                  onTap: () {
                                    setState(() { _disliked = !_disliked; if (_disliked) _liked = false; });
                                    _audioHandler.customAction('dislikeSong');
                                  },
                                ),
                                const SizedBox(width: 10),
                                _chip(
                                  icon: _isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                  label: 'Favorit',
                                  active: _isFavorite,
                                  onTap: () => _audioHandler.customAction('toggleFavorite'),
                                ),
                              ],
                            ),

                            const SizedBox(height: 24),

                            // Transport controls: prev | play/pause | next
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _roundBtn(
                                  icon: Icons.skip_previous_rounded,
                                  color: TvColors.textPrimary,
                                  iconSize: 28,
                                  size: 50,
                                  onTap: () => _audioHandler.skipToPrevious(),
                                ),
                                const SizedBox(width: 16),
                                MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onTap: () => _isPlaying ? _audioHandler.pause() : _audioHandler.play(),
                                    child: Container(
                                      width: 64,
                                      height: 64,
                                      decoration: BoxDecoration(
                                        color: TvColors.primary,
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: TvColors.primary.withValues(alpha: 0.35),
                                            blurRadius: 16,
                                            spreadRadius: 2,
                                          ),
                                        ],
                                      ),
                                      child: AnimatedSwitcher(
                                        duration: const Duration(milliseconds: 150),
                                        child: Icon(
                                          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                          key: ValueKey('fp-pp-$_isPlaying'),
                                          color: Colors.white,
                                          size: 36,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                _roundBtn(
                                  icon: Icons.skip_next_rounded,
                                  color: TvColors.textPrimary,
                                  iconSize: 28,
                                  size: 50,
                                  onTap: () => _audioHandler.skipToNext(),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 1),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? TvColors.primary.withValues(alpha: 0.15)
                : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: active ? TvColors.primary : TvColors.textSecondary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: active ? TvColors.primary : TvColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact song row — no section title, icon + combined text + time.
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
          Text(_timeAgo,
              style: TvTypography.caption.copyWith(fontSize: 11, color: TvColors.textTertiary)),
        ],
      ),
    );
  }
}
