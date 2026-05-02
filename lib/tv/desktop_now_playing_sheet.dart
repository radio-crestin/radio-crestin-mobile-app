import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../appAudioHandler.dart';
import '../services/station_data_service.dart';
import '../types/Station.dart';
import 'tv_shell.dart';
import 'tv_theme.dart';

/// Full-screen now-playing panel for desktop.
///
/// Mirrors the Android TV layout (artwork + metadata + transport) but trims
/// the dpad/focus chrome and adds desktop affordances: hover-lit buttons,
/// tooltips, keyboard shortcuts (Esc, Space, ←/→, F, L, D), and a top bar
/// with close + favorite shortcuts.
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
  final FocusNode _keyboardFocus =
      FocusNode(debugLabel: 'desktop-np-keyboard');

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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keyboardFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _keyboardFocus.dispose();
    super.dispose();
  }

  bool get _isFavorite =>
      _station != null && _favoriteSlugs.contains(_station!.slug);

  List<TvSongEntry> get _prevSongs =>
      widget.songHistory.length > 1 ? widget.songHistory.sublist(1) : [];

  void _close() => Navigator.of(context).maybePop();
  void _togglePlay() =>
      _isPlaying ? _audioHandler.pause() : _audioHandler.play();
  void _toggleLike() {
    setState(() {
      _liked = !_liked;
      if (_liked) _disliked = false;
    });
    _audioHandler.customAction('likeSong');
  }

  void _toggleDislike() {
    setState(() {
      _disliked = !_disliked;
      if (_disliked) _liked = false;
    });
    _audioHandler.customAction('dislikeSong');
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.mediaTrackNext) {
      _audioHandler.skipToNext();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.mediaTrackPrevious) {
      _audioHandler.skipToPrevious();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyF) {
      _audioHandler.customAction('toggleFavorite');
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyL) {
      _toggleLike();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyD) {
      _toggleDislike();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final station = _station;
    if (station == null) {
      return Container(
        decoration: const BoxDecoration(
          color: _NowPlayingPalette.panel,
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        child: const Center(
            child: CircularProgressIndicator(color: TvColors.primary)),
      );
    }

    final prevSongs = _prevSongs;

    final transport = _TransportRow(
      isPlaying: _isPlaying,
      liked: _liked,
      disliked: _disliked,
      onPrev: _audioHandler.skipToPrevious,
      onPlay: _togglePlay,
      onNext: _audioHandler.skipToNext,
      onLike: _toggleLike,
      onDislike: _toggleDislike,
    );

    return Focus(
      focusNode: _keyboardFocus,
      onKeyEvent: _onKey,
      child: Container(
        decoration: const BoxDecoration(
          color: _NowPlayingPalette.panel,
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            const hPad = 28.0;
            const gap = 28.0;
            const rightMin = 340.0;
            const artworkMax = 320.0;

            final innerWidth =
                constraints.maxWidth - (hPad * 2) - gap;
            final maxArtFromWidth =
                (innerWidth - rightMin).clamp(220.0, artworkMax);
            final artworkSize = maxArtFromWidth.clamp(220.0, artworkMax);

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TopBar(
                  isFavorite: _isFavorite,
                  onClose: _close,
                  onFavorite: () =>
                      _audioHandler.customAction('toggleFavorite'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(hPad, 4, hPad, 24),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _Artwork(station: station, size: artworkSize),
                        const SizedBox(width: gap),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _SongMeta(station: station),
                              const SizedBox(height: 16),
                              // Always reserve space for 3 recent songs so
                              // the modal doesn't reflow when history loads.
                              _RecentSongs(songs: prevSongs),
                              const SizedBox(height: 18),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: transport,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Solid colors for the now-playing panel. No transparency.
class _NowPlayingPalette {
  static const Color panel = Color(0xFF15131A);
  static const Color cardBg = Color(0xFF1F1B26);
  static const Color hoverBg = Color(0xFF2A2532);
}

// ─── Pieces ────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final bool isFavorite;
  final VoidCallback onClose;
  final VoidCallback onFavorite;

  const _TopBar({
    required this.isFavorite,
    required this.onClose,
    required this.onFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          _IconBtn(
            icon: Icons.close_rounded,
            tooltip: 'Închide',
            onTap: onClose,
            size: 34,
            iconSize: 18,
            bg: _NowPlayingPalette.cardBg,
          ),
          const Spacer(),
          _IconBtn(
            icon: isFavorite
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            tooltip:
                isFavorite ? 'Elimină de la favorite' : 'Adaugă la favorite',
            onTap: onFavorite,
            size: 36,
            iconSize: 20,
            color: isFavorite ? TvColors.primary : TvColors.textSecondary,
            bg: isFavorite
                ? const Color(0xFF3A1620)
                : _NowPlayingPalette.cardBg,
          ),
        ],
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  final Station station;
  final double size;

  const _Artwork({required this.station, required this.size});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child: Container(
        key: ValueKey('fp-art-${station.artUri}'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 36,
              spreadRadius: 4,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: station.displayThumbnail(cacheWidth: (size * 2).toInt()),
        ),
      ),
    );
  }
}

class _SongMeta extends StatelessWidget {
  final Station station;
  // Reserved heights — keep the layout stable regardless of the
  // current song's title length or whether artist metadata is present.
  static const double _stationLineH = 20.0;
  static const double _songFontSize = 26.0;
  static const double _songLineH = _songFontSize * 1.2;
  static const double _songSlotH = _songLineH * 2;
  static const double _artistSlotH = 22.0;
  static const double _listenersSlotH = 18.0;

  const _SongMeta({required this.station});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Station title — small, secondary, like Apple/Android TV.
        SizedBox(
          width: double.infinity,
          height: _stationLineH,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              station.title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: TvColors.textSecondary,
                letterSpacing: 0.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Song title — fixed two-line slot, stable across title-length changes.
        SizedBox(
          height: _songSlotH,
          width: double.infinity,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Align(
              key: ValueKey('fp-s-${station.songId}'),
              alignment: Alignment.topLeft,
              child: Text(
                station.songTitle.isNotEmpty
                    ? station.songTitle
                    : 'Live Radio',
                style: const TextStyle(
                  fontSize: _songFontSize,
                  fontWeight: FontWeight.w700,
                  color: TvColors.textPrimary,
                  height: 1.2,
                  letterSpacing: -0.3,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        // Artist — fixed one-line slot, blank when missing (no shift).
        SizedBox(
          height: _artistSlotH,
          width: double.infinity,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Align(
              key: ValueKey('fp-a-${station.songId}'),
              alignment: Alignment.centerLeft,
              child: Text(
                station.songArtist,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: TvColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: _listenersSlotH,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.headphones_rounded,
                  size: 13, color: TvColors.textTertiary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${station.totalListeners ?? 0} ascultători',
                  style: TvTypography.caption.copyWith(fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RecentSongs extends StatelessWidget {
  final List<TvSongEntry> songs;
  static const int _slotCount = 3;
  static const double _rowHeight = 36.0;

  const _RecentSongs({required this.songs});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                'Melodii recente',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: TvColors.textPrimary,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  height: 1,
                  color: TvColors.divider.withValues(alpha: 0.35),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Fixed-height slot list — 3 rows always — to prevent layout shift.
          SizedBox(
            height: _rowHeight * _slotCount,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(_slotCount, (i) {
                final entry = i < songs.length ? songs[i] : null;
                return SizedBox(
                  height: _rowHeight,
                  child: entry == null
                      ? const _EmptySongSlot()
                      : _SongRow(entry: entry),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptySongSlot extends StatelessWidget {
  const _EmptySongSlot();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            Icons.music_note_rounded,
            size: 14,
            color: TvColors.textTertiary.withValues(alpha: 0.35),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 8,
              decoration: BoxDecoration(
                color: _NowPlayingPalette.cardBg,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransportRow extends StatelessWidget {
  final bool isPlaying;
  final bool liked;
  final bool disliked;
  final VoidCallback onPrev;
  final VoidCallback onPlay;
  final VoidCallback onNext;
  final VoidCallback onLike;
  final VoidCallback onDislike;

  const _TransportRow({
    required this.isPlaying,
    required this.liked,
    required this.disliked,
    required this.onPrev,
    required this.onPlay,
    required this.onNext,
    required this.onLike,
    required this.onDislike,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconBtn(
          icon:
              liked ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined,
          tooltip: 'Îmi place',
          onTap: onLike,
          size: 40,
          iconSize: 18,
          color: liked ? TvColors.primary : TvColors.textSecondary,
          bg: liked
              ? const Color(0xFF3A1620)
              : _NowPlayingPalette.cardBg,
        ),
        const SizedBox(width: 12),
        _IconBtn(
          icon: Icons.skip_previous_rounded,
          tooltip: 'Stația anterioară',
          onTap: onPrev,
          size: 44,
          iconSize: 24,
          color: TvColors.textPrimary,
          bg: _NowPlayingPalette.cardBg,
        ),
        const SizedBox(width: 12),
        _PlayButton(isPlaying: isPlaying, onTap: onPlay),
        const SizedBox(width: 12),
        _IconBtn(
          icon: Icons.skip_next_rounded,
          tooltip: 'Stația următoare',
          onTap: onNext,
          size: 44,
          iconSize: 24,
          color: TvColors.textPrimary,
          bg: _NowPlayingPalette.cardBg,
        ),
        const SizedBox(width: 12),
        _IconBtn(
          icon: disliked
              ? Icons.thumb_down_alt_rounded
              : Icons.thumb_down_alt_outlined,
          tooltip: 'Nu-mi place',
          onTap: onDislike,
          size: 40,
          iconSize: 18,
          color: disliked ? TvColors.primary : TvColors.textSecondary,
          bg: disliked
              ? const Color(0xFF3A1620)
              : _NowPlayingPalette.cardBg,
        ),
      ],
    );
  }
}

class _PlayButton extends StatefulWidget {
  final bool isPlaying;
  final VoidCallback onTap;

  const _PlayButton({required this.isPlaying, required this.onTap});

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.isPlaying ? 'Pauză' : 'Redă',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 56,
            height: 56,
            transform: Matrix4.identity()
              ..scaleByDouble(
                  _hover ? 1.05 : 1.0, _hover ? 1.05 : 1.0, 1.0, 1.0),
            transformAlignment: Alignment.center,
            decoration: BoxDecoration(
              color: TvColors.primary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: TvColors.primary
                      .withValues(alpha: _hover ? 0.45 : 0.3),
                  blurRadius: _hover ? 18 : 12,
                  spreadRadius: _hover ? 2 : 1,
                ),
              ],
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: Icon(
                widget.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                key: ValueKey('fp-pp-${widget.isPlaying}'),
                color: Colors.white,
                size: 30,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Generic icon button with hover lift, tooltip, and pointer cursor.
class _IconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? bg;

  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 44,
    this.iconSize = 22,
    this.color,
    this.bg,
  });

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? TvColors.textSecondary;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: _hover
                  ? _NowPlayingPalette.hoverBg
                  : (widget.bg ?? _NowPlayingPalette.cardBg),
              shape: BoxShape.circle,
            ),
            child: Icon(widget.icon, color: color, size: widget.iconSize),
          ),
        ),
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  final TvSongEntry entry;
  const _SongRow({required this.entry});

  String get _timeAgo {
    final d = DateTime.now().difference(entry.timestamp);
    if (d.inSeconds < 30) return 'acum';
    if (d.inSeconds < 60) return 'acum ${d.inSeconds}s';
    if (d.inMinutes == 1) return 'acum 1 min';
    if (d.inMinutes < 60) return 'acum ${d.inMinutes} min';
    if (d.inHours == 1) return 'acum 1 oră';
    if (d.inHours < 24) return 'acum ${d.inHours} ore';
    return 'acum ${d.inDays} zile';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.music_note_rounded,
              size: 14, color: TvColors.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: entry.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: TvColors.textPrimary,
                    ),
                  ),
                  if (entry.artist.isNotEmpty)
                    TextSpan(
                      text: '  ·  ${entry.artist}',
                      style: TvTypography.caption.copyWith(
                        fontSize: 12,
                        color: TvColors.textSecondary,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _timeAgo,
            style: TvTypography.caption
                .copyWith(fontSize: 11, color: TvColors.textTertiary),
          ),
        ],
      ),
    );
  }
}
