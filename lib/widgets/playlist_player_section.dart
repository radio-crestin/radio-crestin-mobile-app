import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/theme.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

import '../appAudioHandler.dart';
import '../services/playlist_controller.dart';
import '../services/video_quality.dart';
import '../types/Station.dart';
import '../types/playlist_item.dart';
import '../utils.dart';
import 'animated_play_button.dart';
import 'bottom_toast.dart';
import 'default_artwork.dart';
import 'player_video_surface.dart';
import 'video_overlay_controls.dart';
import 'video_thumbnail_image.dart';
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

/// Whether to overlay the "won't play in background" notice on the media
/// surface. True only for an active YouTube item: its inline iframe cannot keep
/// playing once the app is backgrounded or the screen locks, so the notice is a
/// persistent, subtle reminder. Pure and top-level so it is trivially testable.
bool showYoutubeBackgroundNotice({
  required bool isYoutubeContent,
  required PlaylistItem? item,
}) =>
    isYoutubeContent && item != null && item.type.isYoutube;

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
  bool _repeatOne = false;
  bool _audioOnlyFallback = false;
  Set<int> _failedIds = const {};
  List<VideoQuality> _qualities = const [];
  OverlayEntry? _skipToast;

  /// The persistent below-video scrubber is shown only for audio items: video
  /// items carry their scrubber on the video overlay, and YouTube items use the
  /// native iframe controls (both would otherwise be a confusing duplicate).
  bool get _showBelowScrubber => _currentItem?.type == PlaylistItemType.audio;

  @override
  void initState() {
    super.initState();
    final c = _controller;
    _items = c.items.value;
    _currentIndex = c.currentIndex.value;
    _currentItem = c.currentItem.value;
    _isVideoContent = c.isVideoContent.value;
    _isYoutubeContent = c.isYoutubeContent.value;
    _repeatOne = c.repeatOne.value;
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
      // Red error toast naming the element that failed (the controller
      // includes the item's display name in the message).
      _skipToast = showBottomToast(
        context,
        title: 'Element indisponibil',
        message: message,
        icon: Icons.error_rounded,
        isError: true,
        duration: const Duration(seconds: 3),
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
    _subs.add(c.repeatOne.stream.listen((v) {
      if (mounted) setState(() => _repeatOne = v);
    }));
    _qualities = widget.audioHandler.videoService.qualities;
    _subs.add(widget.audioHandler.videoService.qualitiesStream.listen((q) {
      if (mounted) setState(() => _qualities = q);
    }));
  }

  /// Opens the shared quality sheet for the current video item and applies
  /// the selection on the video player.
  Future<void> _openQualitySheet() async {
    final vs = widget.audioHandler.videoService;
    final chosen = await showVideoQualitySheet(
      context,
      qualities: _qualities,
      selectedId: vs.selectedQuality.id,
    );
    if (chosen != null) await vs.setVideoQuality(chosen);
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
    return LayoutBuilder(
      builder: (context, constraints) => _buildBody(context, constraints),
    );
  }

  Widget _buildBody(BuildContext context, BoxConstraints constraints) {
    // Cap the 16:9 media so the controls below it (title, scrubber, transport)
    // and the track list always fit — and stay on-screen and TAPPABLE. Without
    // this, a short/landscape panel height lets the full-width 16:9 box overflow
    // the Column and push the transport row into the clipped region, where its
    // prev/next taps silently do nothing (the reported "next button doesn't
    // work; only tapping a row does" bug).
    const double reservedForControls = 210.0;
    final double availWidth = constraints.maxWidth - 24.0; // 12px side padding
    final double maxMediaHeight = constraints.maxHeight.isFinite
        ? (constraints.maxHeight - reservedForControls).clamp(80.0, 100000.0)
        : double.infinity;
    double mediaWidth = availWidth;
    double mediaHeight = mediaWidth * 9 / 16;
    if (mediaHeight > maxMediaHeight) {
      mediaHeight = maxMediaHeight;
      mediaWidth = mediaHeight * 16 / 9;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Height-capped 16:9 media area, centered when width-constrained.
        // [IgnoreDraggableWidget] locks the sliding panel while a pointer is on
        // the media surface: touches (taps, scrubs, pinches) interact with the
        // video instead of dragging the panel down.
        Center(
          child: SizedBox(
            width: mediaWidth,
            height: mediaHeight,
            child: IgnoreDraggableWidget(
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
        // Publish date under the title, when the backend provides one for the
        // current item (e.g. a dated live-stream recording). Hidden otherwise.
        if (_currentItem?.publishedAt != null) ...[
          const SizedBox(height: 4),
          Text(
            formatPlaylistDate(_currentItem!.publishedAt!),
            key: ValueKey('pl-date-${_currentItem?.id}'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 10),
        // Persistent scrubber for audio items only (video → overlay scrubber,
        // YouTube → native controls). Same styling as the overlay seek bar.
        if (_showBelowScrubber)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: _VodProgressBar(
              controller: _controller,
              seekable: true,
            ),
          ),
        const SizedBox(height: 6),
        // Transport below the title: [quality] [prev] [play/pause] [next]
        // [fullscreen?]. Video items expose fullscreen on the video surface's
        // own bottom-right corner button (so no redundant transport one here);
        // YouTube items have no such corner button (the iframe owns its chrome),
        // so they keep a transport fullscreen affordance. Play/pause routes
        // through the handler for every item type.
        _Transport(
          audioHandler: widget.audioHandler,
          playButtonKey: _playButtonKey,
          repeatOne: _repeatOne,
          onToggleRepeat: _controller.toggleRepeatOne,
          onQuality: _isVideoContent && _qualities.length > 1
              ? _openQualitySheet
              : null,
          onFullscreen:
              _isYoutubeContent ? _controller.requestYoutubeFullscreen : null,
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
      // playing (the play/pause command channel is unaffected). The rounded
      // clip matches the media_kit video frame for a consistent maximized look.
      child = ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        child: Offstage(
          offstage: !panelExpanded,
          child: YoutubeIframePlayer(
            item: item!,
            controller: controller,
          ),
        ),
      );
    } else if (isVideoContent) {
      kind = 'video-${item?.id}';
      // Big video with the YouTube-style overlay: draggable seek bar, prev/next,
      // double-tap ±10s and fullscreen. VOD (playlist items are not live).
      child = VideoPlayerStage(
        videoService: audioHandler.videoService,
        title: item?.title ?? station.displayTitle,
        isLive: false,
        onPlay: audioHandler.play,
        onPause: audioHandler.pause,
        onSeek: (d) => controller.seek(d),
        // Enable the seek bar right away using the item's known length, before
        // libmpv reports its own duration.
        fallbackDuration: item?.durationSeconds != null
            ? Duration(seconds: item!.durationSeconds!)
            : null,
      );
    } else {
      kind = 'audio-${item?.id}';
      // Empty-string thumbnails (common on the live playlist API) must fall
      // back to the station artwork, exactly like a null.
      final itemThumb = item?.thumbnailUrl;
      child = _AudioArtwork(
        thumbnailUrl: (itemThumb != null && itemThumb.isNotEmpty)
            ? itemThumb
            : station.thumbnailUrl,
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
          // Persistent "won't play in background" reminder on YouTube items.
          if (showYoutubeBackgroundNotice(
              isYoutubeContent: isYoutubeContent, item: item))
            const Positioned(
              left: 8,
              bottom: 8,
              child: YoutubeBackgroundChip(),
            ),
        ],
      ),
    );
  }
}

/// Audio items present like a radio station: the square artwork card with the
/// station look (surface color, [AppRadius.artwork] corners and the soft
/// station shadow), centered in the stable 16:9 media area. Thumbnail chain:
/// item → station → music-note placeholder.
class _AudioArtwork extends StatelessWidget {
  const _AudioArtwork({required this.thumbnailUrl});

  final String? thumbnailUrl;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius:
                const BorderRadius.all(Radius.circular(AppRadius.artwork)),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withValues(alpha: 0.35),
                blurRadius: 4,
                offset: const Offset(2, 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius:
                const BorderRadius.all(Radius.circular(AppRadius.artwork)),
            child: (thumbnailUrl != null && thumbnailUrl!.isNotEmpty)
                ? Utils.displayImage(thumbnailUrl!,
                    cache: true, cacheWidth: 400)
                : const DefaultArtwork(),
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
    final total = hasDuration ? formatPlaylistDuration(_duration!) : '--:--';

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3.0,
            activeTrackColor: AppColors.primary,
            inactiveTrackColor: Theme.of(context)
                .colorScheme
                .onSurfaceVariant
                .withValues(alpha: 0.25),
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
                    widget.controller.seek(Duration(milliseconds: v.round()));
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
    required this.repeatOne,
    required this.onToggleRepeat,
    this.onQuality,
    this.onFullscreen,
  });

  final AppAudioHandler audioHandler;
  final GlobalKey<AnimatedPlayButtonState> playButtonKey;

  /// Whether single-item repeat is active (highlights the repeat button).
  final bool repeatOne;

  /// Toggles single-item repeat (leftmost button).
  final VoidCallback onToggleRepeat;

  /// Quality picker, shown right of "next" for multi-quality video items.
  final VoidCallback? onQuality;

  /// Fullscreen action shown right of "next" — video items enter media_kit
  /// fullscreen, YouTube items enter the iframe fullscreen.
  final VoidCallback? onFullscreen;

  /// Side length of the round secondary buttons (10px padding + 30px icon) —
  /// also the size of the invisible spacer that keeps the prev/play/next
  /// cluster dead-center when the two sides hold a different number of buttons.
  static const double _sideButtonSize = 50.0;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;

    // Left cluster: repeat (always). Right cluster: fullscreen and/or quality.
    // Both sides are padded with invisible ghosts to equal width so the
    // prev/play/next trio stays dead-center regardless of how many secondary
    // controls the current item exposes.
    final leftControls = <Widget>[
      _RoundIconButton(
        icon: Icons.repeat_rounded,
        color: repeatOne ? AppColors.primary : onSurface,
        onTap: onToggleRepeat,
      ),
    ];
    final rightControls = <Widget>[
      if (onFullscreen != null)
        _RoundIconButton(
          icon: Icons.fullscreen_rounded,
          color: onSurface,
          onTap: onFullscreen!,
        ),
      if (onQuality != null)
        _RoundIconButton(
          icon: Icons.high_quality_rounded,
          color: onSurface,
          onTap: onQuality!,
        ),
    ];
    // Balance the two sides with ghosts so the center trio never shifts.
    while (leftControls.length < rightControls.length) {
      leftControls.insert(0, const _GhostButton());
    }
    while (rightControls.length < leftControls.length) {
      rightControls.add(const _GhostButton());
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final w in leftControls) ...[w, const SizedBox(width: 12)],
        _RoundIconButton(
          icon: Icons.skip_previous_rounded,
          color: onSurface,
          onTap: () {
            playButtonKey.currentState?.notifyWillPlay();
            audioHandler.skipToPrevious();
          },
        ),
        const SizedBox(width: 12),
        AnimatedPlayButton(
          key: playButtonKey,
          playbackStateStream: audioHandler.playbackState,
          iconSize: 48,
          iconColor: Theme.of(context).colorScheme.onPrimary,
          backgroundColor: Theme.of(context).bottomAppBarTheme.color,
          onPlay: audioHandler.play,
          onPause: audioHandler.pause,
          onStop: audioHandler.stop,
        ),
        const SizedBox(width: 12),
        _RoundIconButton(
          icon: Icons.skip_next_rounded,
          color: onSurface,
          onTap: () {
            playButtonKey.currentState?.notifyWillPlay();
            audioHandler.skipToNext();
          },
        ),
        for (final w in rightControls) ...[const SizedBox(width: 12), w],
      ],
    );
  }
}

/// Round, tappable secondary transport control (repeat / prev / next /
/// fullscreen / quality): a 30px icon with 10px padding (50x50 hit target).
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Icon(icon, size: 30, color: color),
      ),
    );
  }
}

/// Invisible 50x50 stand-in matching [_RoundIconButton]'s footprint, used to
/// keep the prev/play/next trio centered when the two sides differ in count.
class _GhostButton extends StatelessWidget {
  const _GhostButton();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: _Transport._sideButtonSize,
      height: _Transport._sideButtonSize,
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

  /// Neutral placeholder shown while a thumbnail resolves (or when none exists):
  /// the station artwork if available, else the branded default tile with a
  /// type-appropriate glyph.
  Widget _thumbnailPlaceholder() {
    final stationThumb = fallbackThumbnailUrl;
    if (stationThumb != null && stationThumb.isNotEmpty) {
      return Utils.displayImage(stationThumb, cache: true, cacheWidth: 96);
    }
    return DefaultArtwork(icon: _typeIcon);
  }

  /// Thumbnail chain: the item's own `thumbnail_url` → (video items) the video's
  /// first frame → the shared placeholder.
  Widget _thumbnailChild() {
    final ownThumb = item.thumbnailUrl;
    if (ownThumb != null && ownThumb.isNotEmpty) {
      return Utils.displayImage(ownThumb, cache: true, cacheWidth: 96);
    }
    if (item.type == PlaylistItemType.video && item.url.isNotEmpty) {
      return VideoThumbnailImage(
        videoUrl: item.url,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        placeholder: _thumbnailPlaceholder(),
      );
    }
    return _thumbnailPlaceholder();
  }

  @override
  Widget build(BuildContext context) {
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
              child: Row(
                children: [
                  ClipRRect(
                    // Thumbnail image fills this clip with no gap, so it takes
                    // the small-thumbnail radius directly.
                    borderRadius: const BorderRadius.all(
                        Radius.circular(AppRadius.thumbnail)),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: _thumbnailChild(),
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
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title.isNotEmpty
                                    ? item.title
                                    : 'Fără titlu',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: isCurrent
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: isCurrent
                                      ? AppColors.primary
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                              // Publish date subtitle, when provided by the
                              // backend for this item (null otherwise → hidden).
                              if (item.publishedAt != null)
                                Text(
                                  formatPlaylistDate(item.publishedAt!),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                            ],
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
