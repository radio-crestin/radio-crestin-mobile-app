import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/theme.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

import '../appAudioHandler.dart';
import '../services/playlist_controller.dart';
import '../types/Station.dart';
import '../types/playlist_item.dart';
import '../utils.dart';
import 'animated_play_button.dart';
import 'bottom_toast.dart';
import 'player_video_surface.dart';
import 'youtube_iframe_player.dart';

/// Formats a duration as `m:ss` (or `h:mm:ss` past an hour) for the VOD
/// scrubber labels. Top-level and pure so it is trivially unit-testable.
String formatPlaylistDuration(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final totalSeconds = d.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    final mm = minutes.toString().padLeft(2, '0');
    return '$hours:$mm:$ss';
  }
  return '$minutes:$ss';
}

/// The playlist-specific body of the full player: media surface (audio / video
/// / YouTube), current-item counter + title, a VOD scrubber, transport controls
/// and a live-reconciling track list.
///
/// Subscribes to [PlaylistController] streams and drives playback through it
/// (and the routed [AppAudioHandler] transport). The inline YouTube player is
/// kept mounted by the full player so YouTube audio survives collapsing to the
/// mini player. Play/pause for every item type (including YouTube) goes through
/// [AppAudioHandler], so `playbackState` is the single source of truth.
class PlaylistPlayerSection extends StatefulWidget {
  const PlaylistPlayerSection({
    super.key,
    required this.audioHandler,
    required this.station,
    this.panelExpanded = true,
  });

  final AppAudioHandler audioHandler;
  final Station station;

  /// Whether the sliding panel is expanded. When false (collapsed to the mini
  /// player) the inline YouTube surface is hidden — the iframe stays mounted and
  /// keeps playing, only its visible surface is suppressed.
  final bool panelExpanded;

  @override
  State<PlaylistPlayerSection> createState() => _PlaylistPlayerSectionState();
}

class _PlaylistPlayerSectionState extends State<PlaylistPlayerSection> {
  final List<StreamSubscription<dynamic>> _subs = [];
  final _playButtonKey = GlobalKey<AnimatedPlayButtonState>();
  final ScrollController _listController = ScrollController();

  static const double _rowExtent = 64.0;

  final PlaylistController _controller = GetIt.instance<PlaylistController>();

  List<PlaylistItem> _items = const [];
  int _currentIndex = -1;
  PlaylistItem? _currentItem;
  bool _isVideoContent = false;
  bool _isYoutubeContent = false;
  bool _audioOnlyFallback = false;
  Set<int> _failedIds = const {};
  OverlayEntry? _skipToast;

  /// A whole-playlist YouTube item — the item-level scrubber is meaningless, so
  /// it stays hidden (single youtube videos keep a working, seekable scrubber).
  bool get _isYoutubePlaylist =>
      _currentItem?.type == PlaylistItemType.youtubePlaylist;

  @override
  void initState() {
    super.initState();
    final c = _controller;
    _items = c.items.value;
    _currentIndex = c.currentIndex.value;
    _currentItem = c.currentItem.value;
    _isVideoContent = c.isVideoContent.value;
    _isYoutubeContent = c.isYoutubeContent.value;
    _audioOnlyFallback = widget.audioHandler.audioOnlyFallback.value;
    _failedIds = c.failedItemIds.value;

    _subs.add(c.items.stream.listen((v) {
      if (mounted) setState(() => _items = v);
    }));
    _subs.add(widget.audioHandler.audioOnlyFallback.stream.listen((v) {
      if (mounted) setState(() => _audioOnlyFallback = v);
    }));
    _subs.add(c.failedItemIds.stream.listen((v) {
      if (mounted) setState(() => _failedIds = v);
    }));
    _subs.add(c.transientMessages.stream.listen((message) {
      if (!mounted) return;
      removeBottomToast(_skipToast);
      _skipToast = showBottomToast(
        context,
        title: 'Element indisponibil',
        message: message,
        icon: Icons.skip_next_rounded,
        duration: const Duration(seconds: 2),
        onDismissed: () => _skipToast = null,
      );
    }));
    _subs.add(c.currentIndex.stream.listen((v) {
      if (mounted) {
        setState(() => _currentIndex = v);
        _scrollToCurrent();
      }
    }));
    _subs.add(c.currentItem.stream.listen((v) {
      if (mounted) setState(() => _currentItem = v);
    }));
    _subs.add(c.isVideoContent.stream.listen((v) {
      if (mounted) setState(() => _isVideoContent = v);
    }));
    _subs.add(c.isYoutubeContent.stream.listen((v) {
      if (mounted) setState(() => _isYoutubeContent = v);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    removeBottomToast(_skipToast);
    _listController.dispose();
    super.dispose();
  }

  void _scrollToCurrent() {
    if (_currentIndex < 0 || !_listController.hasClients) return;
    final target = (_currentIndex * _rowExtent)
        .clamp(0.0, _listController.position.maxScrollExtent);
    _listController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: _MediaSurface(
            audioHandler: widget.audioHandler,
            controller: _controller,
            station: widget.station,
            item: _currentItem,
            isVideoContent: _isVideoContent,
            isYoutubeContent: _isYoutubeContent,
            audioOnlyFallback: _audioOnlyFallback,
            panelExpanded: widget.panelExpanded,
          ),
        ),
        const SizedBox(height: 14),
        // Current item title. The old "n / total" counter row was removed to
        // give the track list more vertical room; the highlighted current row
        // in the list below already conveys position.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: Text(
              _currentItem?.title ?? 'Element indisponibil',
              key: ValueKey('pl-title-${_currentItem?.id}'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        // Scrubber: audio/video VOD and single YouTube videos are seekable; a
        // whole YouTube playlist has no item-level timeline, so it's hidden.
        if (!_isYoutubePlaylist)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: _VodProgressBar(
              controller: _controller,
              seekable: true,
            ),
          ),
        const SizedBox(height: 6),
        // Transport: prev | play/pause | next. Play/pause routes through the
        // handler for every item type (YouTube included).
        _Transport(
          audioHandler: widget.audioHandler,
          playButtonKey: _playButtonKey,
        ),
        const SizedBox(height: 12),
        // Track list — live-reconciling, current item highlighted.
        // Wrapped in [IgnoreDraggableWidget] so touches that start on the list
        // scroll it instead of dragging the sliding panel; the drag handle and
        // the non-list areas above keep dragging the panel as usual.
        Expanded(
          child: IgnoreDraggableWidget(
            child: _TrackList(
              controller: _listController,
              items: _items,
              currentIndex: _currentIndex,
              failedIds: _failedIds,
              rowExtent: _rowExtent,
              stationThumbnailUrl: widget.station.thumbnailUrl,
              onTap: (index) => _controller.playItemAt(index),
            ),
          ),
        ),
      ],
    );
  }
}

/// 16:9 media area that crossfades between the audio artwork, the media_kit
/// video output and the inline YouTube player as the current item changes.
class _MediaSurface extends StatelessWidget {
  const _MediaSurface({
    required this.audioHandler,
    required this.controller,
    required this.station,
    required this.item,
    required this.isVideoContent,
    required this.isYoutubeContent,
    required this.audioOnlyFallback,
    required this.panelExpanded,
  });

  final AppAudioHandler audioHandler;
  final PlaylistController controller;
  final Station station;
  final PlaylistItem? item;
  final bool isVideoContent;
  final bool isYoutubeContent;

  /// True when this (video) item is playing audio-only because video rendering
  /// failed — overlays a subtle "Doar audio" chip on the artwork.
  final bool audioOnlyFallback;
  final bool panelExpanded;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    final String kind;
    if (isYoutubeContent && item != null) {
      kind = 'yt-${item!.id}';
      // The webview lives in the app overlay and follows an inline placeholder;
      // Offstage stops the placeholder compositing so the overlay unlinks and
      // hides while collapsed, WITHOUT unmounting the iframe — audio keeps
      // playing (the play/pause command channel is unaffected).
      child = Offstage(
        offstage: !panelExpanded,
        child: YoutubeIframePlayer(
          item: item!,
          controller: controller,
        ),
      );
    } else if (isVideoContent) {
      kind = 'video-${item?.id}';
      child = PlayerVideoSurface(videoService: audioHandler.videoService);
    } else {
      kind = 'audio-${item?.id}';
      child = _AudioArtwork(
        thumbnailUrl: item?.thumbnailUrl ?? station.thumbnailUrl,
      );
    }

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
              child: KeyedSubtree(key: ValueKey(kind), child: child),
            ),
          ),
          // "Doar audio" chip when video content fell back to audio-only.
          if (audioOnlyFallback && !isYoutubeContent)
            const Positioned(
              top: 8,
              left: 8,
              child: AudioOnlyChip(),
            ),
        ],
      ),
    );
  }
}

/// Centered rounded artwork on a dark backdrop, used for audio-only items so
/// the media area stays a stable 16:9 across item-type changes.
class _AudioArtwork extends StatelessWidget {
  const _AudioArtwork({required this.thumbnailUrl});

  final String? thumbnailUrl;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: AspectRatio(
            aspectRatio: 1,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                child: (thumbnailUrl != null && thumbnailUrl!.isNotEmpty)
                    ? Utils.displayImage(thumbnailUrl!,
                        cache: true, cacheWidth: 400)
                    : const ColoredBox(
                        color: Color(0xFF1E1E1E),
                        child: Icon(Icons.music_note_rounded,
                            color: Colors.white54, size: 40),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// VOD scrubber with elapsed / total labels and drag-to-seek.
class _VodProgressBar extends StatefulWidget {
  const _VodProgressBar({required this.controller, required this.seekable});

  final PlaylistController controller;
  final bool seekable;

  @override
  State<_VodProgressBar> createState() => _VodProgressBarState();
}

class _VodProgressBarState extends State<_VodProgressBar> {
  final List<StreamSubscription<dynamic>> _subs = [];
  Duration _position = Duration.zero;
  Duration? _duration;
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    _position = widget.controller.position.value;
    _duration = widget.controller.duration.value;
    _subs.add(widget.controller.position.stream.listen((p) {
      if (mounted && _dragValue == null) setState(() => _position = p);
    }));
    _subs.add(widget.controller.duration.stream.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = _duration?.inMilliseconds ?? 0;
    final hasDuration = totalMs > 0;
    final positionMs = _position.inMilliseconds
        .clamp(0, hasDuration ? totalMs : _position.inMilliseconds)
        .toDouble();
    final sliderValue = _dragValue ?? positionMs;
    final maxValue = hasDuration ? totalMs.toDouble() : 1.0;

    final elapsed = formatPlaylistDuration(
        Duration(milliseconds: (_dragValue ?? positionMs).round()));
    final total = hasDuration
        ? formatPlaylistDuration(_duration!)
        : '--:--';

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3.0,
            activeTrackColor: AppColors.primary,
            inactiveTrackColor:
                Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.25),
            thumbColor: AppColors.primary,
            overlayColor: AppColors.primary.withValues(alpha: 0.18),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: sliderValue.clamp(0.0, maxValue),
            max: maxValue,
            onChanged: hasDuration && widget.seekable
                ? (v) => setState(() => _dragValue = v)
                : null,
            onChangeEnd: hasDuration && widget.seekable
                ? (v) {
                    widget.controller
                        .seek(Duration(milliseconds: v.round()));
                    setState(() {
                      _position = Duration(milliseconds: v.round());
                      _dragValue = null;
                    });
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(elapsed, style: _labelStyle(context)),
              Text(total, style: _labelStyle(context)),
            ],
          ),
        ),
      ],
    );
  }

  TextStyle _labelStyle(BuildContext context) => TextStyle(
        fontSize: 12,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
}

/// Transport row shared by every playlist item type. Play/pause is the standard
/// [AnimatedPlayButton] routed through [AppAudioHandler] — for YouTube items the
/// handler forwards to the inline iframe, so `playbackState` is the one source
/// of truth for the icon and the action.
class _Transport extends StatelessWidget {
  const _Transport({
    required this.audioHandler,
    required this.playButtonKey,
  });

  final AppAudioHandler audioHandler;
  final GlobalKey<AnimatedPlayButtonState> playButtonKey;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            playButtonKey.currentState?.notifyWillPlay();
            audioHandler.skipToPrevious();
          },
          child: Padding(
            padding: const EdgeInsets.all(10.0),
            child: Icon(Icons.skip_previous_rounded,
                size: 40, color: Theme.of(context).colorScheme.onSurface),
          ),
        ),
        const SizedBox(width: 24),
        AnimatedPlayButton(
          key: playButtonKey,
          playbackStateStream: audioHandler.playbackState,
          iconSize: 52,
          iconColor: Theme.of(context).colorScheme.onPrimary,
          backgroundColor: Theme.of(context).bottomAppBarTheme.color,
          onPlay: audioHandler.play,
          onPause: audioHandler.pause,
          onStop: audioHandler.stop,
        ),
        const SizedBox(width: 24),
        InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            playButtonKey.currentState?.notifyWillPlay();
            audioHandler.skipToNext();
          },
          child: Padding(
            padding: const EdgeInsets.all(10.0),
            child: Icon(Icons.skip_next_rounded,
                size: 40, color: Theme.of(context).colorScheme.onSurface),
          ),
        ),
      ],
    );
  }
}

/// Scrollable, tappable playlist track list. Live updates from the 5s sync
/// reconcile in place (stable keys per item id), so no jumps.
class _TrackList extends StatelessWidget {
  const _TrackList({
    required this.controller,
    required this.items,
    required this.currentIndex,
    required this.failedIds,
    required this.rowExtent,
    required this.stationThumbnailUrl,
    required this.onTap,
  });

  final ScrollController controller;
  final List<PlaylistItem> items;
  final int currentIndex;
  final Set<int> failedIds;
  final double rowExtent;
  final String? stationThumbnailUrl;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          'Lista este goală',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      controller: controller,
      itemExtent: rowExtent,
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _TrackRow(
          key: ValueKey('pl-row-${item.id}'),
          item: item,
          isCurrent: index == currentIndex,
          hasFailed: failedIds.contains(item.id),
          fallbackThumbnailUrl: stationThumbnailUrl,
          onTap: () => onTap(index),
        );
      },
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    super.key,
    required this.item,
    required this.isCurrent,
    required this.hasFailed,
    required this.fallbackThumbnailUrl,
    required this.onTap,
  });

  final PlaylistItem item;
  final bool isCurrent;

  /// True when this item failed to play — dims the row and shows an error icon.
  final bool hasFailed;
  final String? fallbackThumbnailUrl;
  final VoidCallback onTap;

  IconData get _typeIcon {
    switch (item.type) {
      case PlaylistItemType.video:
        return Icons.movie_outlined;
      case PlaylistItemType.youtube:
        return Icons.smart_display_outlined;
      case PlaylistItemType.youtubePlaylist:
        return Icons.playlist_play_rounded;
      case PlaylistItemType.audio:
        return Icons.music_note_rounded;
      case PlaylistItemType.unknown:
        return Icons.help_outline_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumb = (item.thumbnailUrl != null && item.thumbnailUrl!.isNotEmpty)
        ? item.thumbnailUrl!
        : (fallbackThumbnailUrl ?? '');
    final duration = item.durationSeconds != null && item.durationSeconds! > 0
        ? formatPlaylistDuration(Duration(seconds: item.durationSeconds!))
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Opacity(
        // Failed items dim so they read as unavailable but remain tappable
        // (a later tap can retry). The current row never dims.
        opacity: hasFailed && !isCurrent ? 0.45 : 1.0,
        child: Material(
        color: isCurrent
            ? Theme.of(context).cardColorSelected
            : Colors.transparent,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: thumb.isNotEmpty
                        ? Utils.displayImage(thumb, cache: true, cacheWidth: 96)
                        : const ColoredBox(
                            color: Color(0xFF2A2A2A),
                            child: Icon(Icons.music_note_rounded,
                                color: Colors.white38, size: 20),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: [
                      if (isCurrent) ...[
                        const Icon(Icons.equalizer_rounded,
                            size: 15, color: AppColors.primary),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          item.title.isNotEmpty ? item.title : 'Fără titlu',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                isCurrent ? FontWeight.w700 : FontWeight.w500,
                            color: isCurrent
                                ? AppColors.primary
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Failed items show an error glyph in place of the type icon.
                Icon(hasFailed ? Icons.error_outline_rounded : _typeIcon,
                    size: 16,
                    color: hasFailed
                        ? AppColors.error
                        : Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.7)),
                if (duration != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    duration,
                    style: TextStyle(
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}
