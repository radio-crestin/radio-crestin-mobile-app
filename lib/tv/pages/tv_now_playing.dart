import 'dart:async';
import 'dart:ui';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../tv_shell.dart';
import '../tv_theme.dart';
import '../widgets/desktop_focusable.dart';

/// Station page (Now Playing).
/// Back (top-left) and favorite (top-right) span full width.
/// Below: artwork left, metadata + recent songs + controls right.
/// All in one Column for D-pad traversal.
class TvNowPlaying extends StatefulWidget {
  final VoidCallback onBrowse;
  final List<TvSongEntry> songHistory;

  const TvNowPlaying({
    super.key,
    required this.onBrowse,
    required this.songHistory,
  });

  @override
  State<TvNowPlaying> createState() => _TvNowPlayingState();
}

class _TvNowPlayingState extends State<TvNowPlaying> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];

  Station? _station;
  List<String> _favoriteSlugs = [];
  bool _liked = false;
  bool _disliked = false;
  bool _isPlaying = false;
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
        (Station? station, List<String> favs) => (station, favs),
      ).listen((data) {
        if (mounted) {
          final newStation = data.$1;
          setState(() {
            _station = newStation;
            _favoriteSlugs = data.$2;
          });
          // Reset like/dislike on song change
          if (newStation != null && newStation.songId != _lastSongId) {
            _lastSongId = newStation.songId;
            _liked = false;
            _disliked = false;
          }
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

  bool get _isFavorite =>
      _station != null && _favoriteSlugs.contains(_station!.slug);

  /// Previous songs = skip index 0 (current song).
  List<TvSongEntry> get _prevSongs =>
      widget.songHistory.length > 1 ? widget.songHistory.sublist(1) : [];

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      widget.onBrowse();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      _audioHandler.skipToNext();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      _audioHandler.skipToPrevious();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _isPlaying ? _audioHandler.pause() : _audioHandler.play();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _audioHandler.customAction('toggleFavorite');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyL) {
      setState(() { _liked = !_liked; if (_liked) _disliked = false; });
      _audioHandler.customAction('likeSong');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyD) {
      setState(() { _disliked = !_disliked; if (_disliked) _liked = false; });
      _audioHandler.customAction('dislikeSong');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _btn({
    required IconData icon,
    required VoidCallback onSelect,
    Color? color,
    double size = 48,
    double iconSize = 24,
    bool autofocus = false,
    Color? bg,
  }) {
    return DesktopFocusable(
      autofocus: autofocus,
      onSelect: onSelect,
      builder: FocusEffects.scaleWithBorder(
        scale: 1.1,
        borderColor: TvColors.primary,
        borderWidth: 2,
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bg ?? TvColors.surfaceVariant.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color ?? TvColors.textSecondary, size: iconSize),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final station = _station;
    if (station == null) {
      return const Center(
        child: CircularProgressIndicator(color: TvColors.primary),
      );
    }

    final prevSongs = _prevSongs;

    return Focus(
      onKeyEvent: _onKeyEvent,
      autofocus: true,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Blurred artwork background
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            child: SizedBox.expand(
              key: ValueKey('bg-${station.id}-${station.artUri}'),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                child: ColorFiltered(
                  colorFilter: ColorFilter.mode(
                    Colors.black.withValues(alpha: 0.65),
                    BlendMode.darken,
                  ),
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
          // Content — one Column, all focusable items reachable
          SafeArea(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: TvSpacing.marginHorizontal,
                vertical: TvSpacing.md,
              ),
              child: Column(
                children: [
                  // TOP ROW: back (left) — favorite (right)
                  // Full width, spans above the artwork
                  Row(
                    children: [
                      _btn(
                        icon: Icons.arrow_back_rounded,
                        size: 40,
                        iconSize: 22,
                        color: Colors.white,
                        bg: Colors.black.withValues(alpha: 0.4),
                        onSelect: widget.onBrowse,
                      ),
                      const Spacer(),
                      _btn(
                        icon: _isFavorite
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 40,
                        iconSize: 22,
                        color: _isFavorite ? TvColors.primary : Colors.white,
                        bg: Colors.black.withValues(alpha: 0.4),
                        onSelect: () =>
                            _audioHandler.customAction('toggleFavorite'),
                      ),
                    ],
                  ),
                  const SizedBox(height: TvSpacing.sm),
                  // MAIN: artwork (left) + metadata/songs/controls (right)
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Artwork
                        Expanded(
                          flex: 4,
                          child: Padding(
                            padding: const EdgeInsets.all(TvSpacing.md),
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 400),
                                  child: Container(
                                    key: ValueKey('art-${station.artUri}'),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(
                                          TvSpacing.radiusLg),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.5),
                                          blurRadius: 40,
                                          spreadRadius: 5,
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(
                                          TvSpacing.radiusLg),
                                      child: station.displayThumbnail(
                                          cacheWidth: 600),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: TvSpacing.lg),
                        // Right side: metadata + songs + controls
                        Expanded(
                          flex: 5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // Station name
                              Text(
                                station.title,
                                style: TvTypography.body.copyWith(
                                    color: TvColors.textSecondary,
                                    fontSize: 17),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: TvSpacing.sm),
                              // Song title
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 250),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    station.songTitle.isNotEmpty
                                        ? station.songTitle
                                        : 'Live Radio',
                                    key: ValueKey('song-${station.songId}'),
                                    style: TvTypography.displayMedium,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              if (station.songArtist.isNotEmpty) ...[
                                const SizedBox(height: TvSpacing.xs),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 250),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      station.songArtist,
                                      key: ValueKey(
                                          'artist-${station.songId}'),
                                      style: TvTypography.title.copyWith(
                                          color: TvColors.textSecondary),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: TvSpacing.sm),
                              Row(
                                children: [
                                  const Icon(Icons.headphones_rounded,
                                      size: 16,
                                      color: TvColors.textTertiary),
                                  const SizedBox(width: TvSpacing.xs),
                                  Text(
                                      '${station.totalListeners ?? 0} ascultători',
                                      style: TvTypography.caption),
                                ],
                              ),
                              // Recent songs above controls
                              if (prevSongs.isNotEmpty) ...[
                                const SizedBox(height: TvSpacing.lg),
                                Text('Melodii recente',
                                    style: TvTypography.title
                                        .copyWith(fontSize: 15)),
                                const SizedBox(height: TvSpacing.sm),
                                ...List.generate(
                                  prevSongs.length.clamp(0, 3),
                                  (i) => _SongTile(entry: prevSongs[i]),
                                ),
                              ],
                              const SizedBox(height: TvSpacing.xl),
                              // Controls
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _btn(
                                    icon: _liked
                                        ? Icons.thumb_up_alt_rounded
                                        : Icons.thumb_up_alt_outlined,
                                    iconSize: 20,
                                    color: _liked ? TvColors.primary : null,
                                    onSelect: () {
                                      setState(() {
                                        _liked = !_liked;
                                        if (_liked) _disliked = false;
                                      });
                                      _audioHandler.customAction('likeSong');
                                    },
                                  ),
                                  const SizedBox(width: TvSpacing.md),
                                  _btn(
                                    icon: Icons.skip_previous_rounded,
                                    color: TvColors.textPrimary,
                                    iconSize: 28,
                                    size: 52,
                                    onSelect: () =>
                                        _audioHandler.skipToPrevious(),
                                  ),
                                  const SizedBox(width: TvSpacing.md),
                                  // Play/Pause — pure DpadFocusable
                                  DesktopFocusable(
                                    autofocus: true,
                                    onSelect: () => _isPlaying
                                        ? _audioHandler.pause()
                                        : _audioHandler.play(),
                                    builder: FocusEffects.scaleWithBorder(
                                      scale: 1.1,
                                      borderColor: Colors.white,
                                      borderWidth: 2,
                                      borderRadius:
                                          BorderRadius.circular(36),
                                    ),
                                    child: Container(
                                      width: 64,
                                      height: 64,
                                      decoration: const BoxDecoration(
                                        color: TvColors.primary,
                                        shape: BoxShape.circle,
                                      ),
                                      child: AnimatedSwitcher(
                                        duration:
                                            const Duration(milliseconds: 150),
                                        child: Icon(
                                          _isPlaying
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          key: ValueKey(_isPlaying),
                                          color: Colors.white,
                                          size: 36,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: TvSpacing.md),
                                  _btn(
                                    icon: Icons.skip_next_rounded,
                                    color: TvColors.textPrimary,
                                    iconSize: 28,
                                    size: 52,
                                    onSelect: () =>
                                        _audioHandler.skipToNext(),
                                  ),
                                  const SizedBox(width: TvSpacing.md),
                                  _btn(
                                    icon: _disliked
                                        ? Icons.thumb_down_alt_rounded
                                        : Icons.thumb_down_alt_outlined,
                                    iconSize: 20,
                                    color:
                                        _disliked ? TvColors.primary : null,
                                    onSelect: () {
                                      setState(() {
                                        _disliked = !_disliked;
                                        if (_disliked) _liked = false;
                                      });
                                      _audioHandler
                                          .customAction('dislikeSong');
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SongTile extends StatelessWidget {
  final TvSongEntry entry;

  const _SongTile({required this.entry});

  String get _timeAgo {
    final diff = DateTime.now().difference(entry.timestamp);
    if (diff.inSeconds < 30) return 'acum';
    if (diff.inSeconds < 60) return 'acum ${diff.inSeconds}s';
    if (diff.inMinutes == 1) return 'acum 1 minut';
    if (diff.inMinutes < 60) return 'acum ${diff.inMinutes} minute';
    if (diff.inHours == 1) return 'acum 1 oră';
    if (diff.inHours < 24) return 'acum ${diff.inHours} ore';
    return 'acum ${diff.inDays} zile';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: TvSpacing.sm),
      child: Row(
        children: [
          const Icon(Icons.music_note_rounded,
              size: 16, color: TvColors.textTertiary),
          const SizedBox(width: TvSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.title,
                  style: TvTypography.label
                      .copyWith(fontSize: 14, color: TvColors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (entry.artist.isNotEmpty)
                  Text(
                    entry.artist,
                    style: TvTypography.caption.copyWith(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: TvSpacing.md),
          Text(_timeAgo, style: TvTypography.caption.copyWith(fontSize: 12)),
        ],
      ),
    );
  }
}
