import 'dart:async';

import 'package:audio_service/audio_service.dart';
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
import '../utils/support_contact.dart';
import 'animated_play_button.dart';
import 'bottom_toast.dart';
import 'contact_support_button.dart';
import 'default_artwork.dart';
import 'player_transport.dart';
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

/// Fixed height of the current-item TITLE slot (two lines at 19px, w700).
///
/// Every slot between the media surface and the transport row has a FIXED
/// height on purpose: a one-line title, a missing publish date or a video item
/// (no below-video scrubber) must never move the prev/play/next cluster. The
/// transport is the one control the user reaches for blind, so it stays at the
/// same pixel for every station type (playlist / video / TV) and item type
/// (audio / video / youtube).
const double kPlaylistTitleSlotHeight = 52.0;

/// Fixed height of the publish-date slot under the title (empty when the item
/// has no date).
const double kPlaylistMetaSlotHeight = 18.0;

/// Height of the below-title scrubber slot WHEN there is a scrubber. Only audio
/// items draw one here; video items carry theirs on the video overlay and
/// YouTube items use the iframe's own chrome.
///
/// The slot is NOT reserved when it is empty: the transport is anchored to the
/// bottom of the section, so the elastic playlist band absorbs the difference
/// and the prev/play/next cluster stays at the very same pixel either way —
/// while a video item gets those 66 points of playlist instead of dead space.
const double kPlaylistScrubberSlotHeight = 66.0;

/// Height of the seek bar inside [kPlaylistScrubberSlotHeight] (the rest holds
/// the elapsed / total labels).
const double kPlaylistSliderHeight = 46.0;

/// Side of the PAINTED "next station" circle on the title row — small, so it
/// reads as a quiet secondary affordance next to the title rather than a third
/// transport button.
const double kPlaylistNextStationCircleSize = 36.0;

/// Side of its TAP TARGET. The painted circle is smaller, but the touch area
/// stays at the platform minimum 44x44, and it still fits inside
/// [kPlaylistTitleSlotHeight] — so the control costs the layout no height at
/// all (it replaced a dedicated 44px row, which the playlist band inherited).
const double kPlaylistNextStationControlSize = 44.0;

/// Height of the collapsed playlist header (the tappable queue pill).
const double kPlaylistQueueHeaderHeight = 60.0;

/// Vertical gaps between the fixed slots, in layout order. Deliberately tight —
/// every point saved here is a point of playlist.
const double _gapAfterMedia = 6.0;
const double _gapAfterMeta = 6.0;
const double _gapAfterQueueHeader = 6.0;

/// Space kept below the transport row, so the prev/play/next cluster sits in
/// the same bottom-anchored band as the classic radio full player's transport
/// (`FullAudioPlayer`, which leaves a gap above its own action row) instead of
/// being glued to the action row underneath the section.
const double _gapBelowTransport = 16.0;

/// Space the layout reserves below the media surface for everything that is not
/// the playlist itself, given the shared [playerTransportRowHeight] and the
/// scrubber slot's height for THIS item (0 when it has no scrubber).
///
/// The 16:9 media box is capped to what is left so the transport can never be
/// pushed into the panel's clipped region — where its prev/next taps silently
/// did nothing (the reported "next button doesn't work" bug).
double playlistControlsReservedHeight(
  double transportRowHeight, {
  double scrubberSlotHeight = kPlaylistScrubberSlotHeight,
}) =>
    _gapAfterMedia +
    kPlaylistTitleSlotHeight +
    kPlaylistMetaSlotHeight +
    _gapAfterMeta +
    kPlaylistQueueHeaderHeight +
    _gapAfterQueueHeader +
    scrubberSlotHeight +
    transportRowHeight +
    _gapBelowTransport;

/// Expand / collapse animation of the playlist list.
const Duration kPlaylistExpandDuration = Duration(milliseconds: 300);

/// Height of one playlist row (also the unit the list scrolls by).
const double kPlaylistRowExtent = 64.0;

/// The playlist opens BY DEFAULT only when the elastic band left over between
/// the queue header and the scrubber can show at least this much — two full
/// rows. Above the threshold, leaving that band empty would just be a hole in
/// the layout; below it, an "expanded" list would be a cramped sliver, so a
/// compact phone, a split-view window or landscape stays collapsed.
const double kPlaylistAutoExpandMinBandHeight = 2 * kPlaylistRowExtent;

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
    final target = (_currentIndex * kPlaylistRowExtent)
        .clamp(0.0, _listController.position.maxScrollExtent);
    _listController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  /// Jumps to the next STATION in the frozen station order (not the next
  /// playlist item). The play button flips to "playing" instantly so the tap
  /// never feels ignored while the next station loads.
  void _playNextStation() {
    _playButtonKey.currentState?.notifyWillPlay();
    widget.audioHandler.skipToNextStation();
  }

  /// Expanding the playlist scrolls it to the playing item once it has laid out.
  void _onListExpanded(bool expanded) {
    if (!expanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToCurrent();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PlaylistPlayerLayout(
      // [IgnoreDraggableWidget] locks the sliding panel while a pointer is on
      // the media surface: touches (taps, scrubs, pinches) interact with the
      // video instead of dragging the panel down.
      media: IgnoreDraggableWidget(
        child: _MediaSurface(
          audioHandler: widget.audioHandler,
          controller: _controller,
          station: widget.station,
          item: _currentItem,
          isVideoContent: _isVideoContent,
          isYoutubeContent: _isYoutubeContent,
          audioOnlyFallback: _audioOnlyFallback,
          itemFailed: _currentItem != null &&
              _failedIds.contains(_currentItem!.id),
          panelExpanded: widget.panelExpanded,
        ),
      ),
      title: _currentItem?.title ?? 'Element indisponibil',
      titleKey: ValueKey('pl-title-${_currentItem?.id}'),
      subtitle: _currentItem?.publishedAt != null
          ? formatPlaylistDate(_currentItem!.publishedAt!)
          : null,
      // Persistent scrubber for audio items only (video → overlay scrubber,
      // YouTube → native controls); the slot stays reserved for the others.
      scrubber: _showBelowScrubber
          ? _VodProgressBar(controller: _controller, seekable: true)
          : null,
      // Transport: [repeat] [prev] [play/pause] [next] [fullscreen?/quality?].
      // Video items expose fullscreen on the video surface's own bottom-right
      // corner button (so no redundant transport one here); YouTube items have
      // no such corner button (the iframe owns its chrome), so they keep a
      // transport fullscreen affordance. Play/pause routes through the handler
      // for every item type.
      transport: PlaylistTransport(
        playbackStateStream: widget.audioHandler.playbackState,
        playButtonKey: _playButtonKey,
        repeatOne: _repeatOne,
        onToggleRepeat: _controller.toggleRepeatOne,
        onPlay: widget.audioHandler.play,
        onPause: widget.audioHandler.pauseFromUser,
        onStop: widget.audioHandler.stop,
        onPrevious: widget.audioHandler.skipToPrevious,
        onNext: widget.audioHandler.skipToNext,
        onQuality: _isVideoContent && _qualities.length > 1
            ? _openQualitySheet
            : null,
        onFullscreen:
            _isYoutubeContent ? _controller.requestYoutubeFullscreen : null,
      ),
      onNextStation: _playNextStation,
      currentIndex: _currentIndex,
      itemCount: _items.length,
      // Track list — live-reconciling, current item highlighted. Wrapped in
      // [IgnoreDraggableWidget] so touches that start on the list scroll it
      // instead of dragging the sliding panel.
      list: IgnoreDraggableWidget(
        child: _TrackList(
          controller: _listController,
          items: _items,
          currentIndex: _currentIndex,
          failedIds: _failedIds,
          rowExtent: kPlaylistRowExtent,
          stationThumbnailUrl: widget.station.thumbnailUrl,
          onTap: (index) => _controller.playItemAt(index),
        ),
      ),
      onExpandedChanged: _onListExpanded,
    );
  }
}

/// The playlist player's stable-layout body, top to bottom:
///
///   media surface → title → date → "Postul următor" → queue header
///   → *expandable playlist* → scrubber → transport
///
/// Everything above the playlist is a fixed-height slot and everything below it
/// is bottom-anchored, so the prev/play/next cluster keeps a constant offset
/// from the bottom of the section — the same offset for every station type,
/// item type, title length, and whether the playlist is open or closed. The
/// playlist itself is the only elastic band: it takes the space between the
/// queue header and the scrubber, which is empty (not absent) while collapsed.
///
/// The order deliberately puts the station-advance pill and the queue card
/// ABOVE the transport so the cluster lands in the same bottom band as the
/// classic radio full player's ([FullAudioPlayer]) — the one control the user
/// reaches for blind never moves between the two layouts.
///
/// Presentational and service-free (widgets and callbacks only) so the whole
/// layout contract — "the transport never moves" and the expand/collapse
/// behavior — is directly widget-testable.
class PlaylistPlayerLayout extends StatefulWidget {
  const PlaylistPlayerLayout({
    super.key,
    required this.media,
    required this.title,
    required this.transport,
    required this.onNextStation,
    required this.currentIndex,
    required this.itemCount,
    required this.list,
    this.titleKey,
    this.subtitle,
    this.scrubber,
    this.onExpandedChanged,
    this.initiallyExpanded,
  });

  /// The 16:9 media surface (artwork / video / YouTube), already wrapped in its
  /// drag lock by the caller.
  final Widget media;

  /// Current item title, shown in the fixed two-line title slot.
  final String title;

  /// Identity of the title for its crossfade (usually the item id).
  final Key? titleKey;

  /// Optional publish date under the title; the slot is reserved regardless.
  final String? subtitle;

  /// Below-title seek bar for audio items; null keeps the slot empty.
  final Widget? scrubber;

  /// The prev / play / next cluster (plus secondary controls).
  final Widget transport;

  /// Jumps to the next station in the frozen station order.
  final VoidCallback onNextStation;

  /// Index of the playing item (-1 when unknown) and the item count, shown on
  /// the collapsed playlist header as "n din total".
  final int currentIndex;
  final int itemCount;

  /// The full playlist, revealed when the header is expanded.
  final Widget list;

  /// Fired whenever the playlist's shown / hidden state settles — on the user's
  /// toggle AND on the automatic first decision.
  final ValueChanged<bool>? onExpandedChanged;

  /// Forces the initial state instead of deciding it from the available space
  /// (see [kPlaylistAutoExpandMinBandHeight]). Null — the default — means
  /// "decide automatically"; a test or a future preference can pin it.
  final bool? initiallyExpanded;

  @override
  State<PlaylistPlayerLayout> createState() => _PlaylistPlayerLayoutState();
}

class _PlaylistPlayerLayoutState extends State<PlaylistPlayerLayout> {
  /// The user's explicit choice, once they have made one. Null means "nobody
  /// has touched the queue header yet", and the state is decided from the space
  /// the elastic band has. A collapse the user asked for therefore STICKS for
  /// this station view, even though the band would happily hold the list.
  late bool? _choice = widget.initiallyExpanded;

  /// Last state handed to [PlaylistPlayerLayout.onExpandedChanged], so the
  /// automatic first decision is reported exactly once (it drives the
  /// scroll-to-playing-item pass) and never re-reported on an unrelated
  /// rebuild.
  bool? _reported;

  /// The band's height as ACTUALLY laid out, measured by the band's own
  /// [LayoutBuilder] rather than derived from the slot arithmetic.
  ///
  /// The arithmetic is only ever an estimate of what the Column will do; the
  /// automatic expand decision must not hinge on it (nor on whatever
  /// constraints the very first frame happened to carry, e.g. while the sliding
  /// panel is still opening). Measuring is safe and cannot oscillate: the band
  /// is an [Expanded], so its height is the SAME whether the list is shown or
  /// not — expanding never changes the measurement that caused it.
  double? _measuredBand;

  void _toggleExpanded(bool current) => setState(() => _choice = !current);

  /// Records the band height the layout really produced; a change re-runs the
  /// automatic decision on the next frame (skipped once the user has chosen).
  void _recordBand(double height) {
    if (_measuredBand == height) return;
    _measuredBand = height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  /// Reports [expanded] after the frame — never during build, and only once the
  /// band has been measured, so a first-frame estimate is never announced.
  void _reportExpanded(bool expanded) {
    if (_measuredBand == null || _reported == expanded) return;
    _reported = expanded;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onExpandedChanged?.call(expanded);
    });
  }

  @override
  Widget build(BuildContext context) {
    final double transportRowHeight =
        playerTransportRowHeight(playerLayoutOf(context));
    // An empty scrubber slot is not reserved — see [kPlaylistScrubberSlotHeight].
    final double scrubberSlotHeight =
        widget.scrubber == null ? 0.0 : kPlaylistScrubberSlotHeight;
    final double reserved = playlistControlsReservedHeight(
      transportRowHeight,
      scrubberSlotHeight: scrubberSlotHeight,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Cap the 16:9 media so every fixed slot below it (title, date,
        // next-station, playlist header, scrubber, transport) still fits. The
        // media is the part that yields — on a very short panel (landscape) it
        // shrinks away entirely rather than pushing the transport into the
        // clipped region, where its taps would silently do nothing.
        final double availWidth = constraints.maxWidth - 24.0; // 12px padding
        final double maxMediaHeight = constraints.maxHeight.isFinite
            ? (constraints.maxHeight - reserved).clamp(0.0, 100000.0)
            : double.infinity;
        double mediaWidth = availWidth;
        double mediaHeight = mediaWidth * 9 / 16;
        if (mediaHeight > maxMediaHeight) {
          mediaHeight = maxMediaHeight;
          mediaWidth = mediaHeight * 16 / 9;
        }

        // Whatever the fixed slots and the media leave over is the elastic
        // band. Open the playlist into it by default when it can show a
        // meaningful slice of the list — an empty band is just a hole, and the
        // transport does not move either way.
        //
        // The MEASURED band wins over this estimate as soon as one frame has
        // been laid out, so the decision reflects the final layout rather than
        // whatever constraints the first frame carried.
        final double estimatedBand = constraints.maxHeight.isFinite
            ? (constraints.maxHeight - reserved - mediaHeight)
                .clamp(0.0, double.infinity)
            : 0.0;
        final bool expanded = _choice ??
            (_measuredBand ?? estimatedBand) >= kPlaylistAutoExpandMinBandHeight;
        _reportExpanded(expanded);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: SizedBox(
                width: mediaWidth,
                height: mediaHeight,
                child: widget.media,
              ),
            ),
            const SizedBox(height: _gapAfterMedia),
            _TitleSlot(
              title: widget.title,
              titleKey: widget.titleKey,
              onNextStation: widget.onNextStation,
            ),
            _MetaSlot(subtitle: widget.subtitle),
            const SizedBox(height: _gapAfterMeta),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: PlaylistQueueHeader(
                expanded: expanded,
                title: widget.title,
                currentIndex: widget.currentIndex,
                itemCount: widget.itemCount,
                onTap: () => _toggleExpanded(expanded),
              ),
            ),
            const SizedBox(height: _gapAfterQueueHeader),
            // The expandable playlist lives in the ONE flexible band of the
            // layout, between the queue header and the bottom-anchored
            // scrubber + transport block. [Expanded] keeps that band the same
            // size whether the list is shown or not, so expanding never moves
            // the transport — the list simply fills (and scrolls inside) the
            // space that was already empty, animating open via [AnimatedSize].
            Expanded(
              child: LayoutBuilder(
                builder: (context, band) {
                  final double bandHeight =
                      band.maxHeight.isFinite ? band.maxHeight : 0.0;
                  _recordBand(bandHeight);
                  return ClipRect(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: AnimatedSize(
                        duration: kPlaylistExpandDuration,
                        curve: Curves.fastOutSlowIn,
                        alignment: Alignment.topCenter,
                        // The list is given the band's FULL height explicitly.
                        // Left to size itself under [Align]'s loose constraints
                        // it would settle on its natural height and leave a gap
                        // above the scrubber; tight here, the viewport always
                        // fills the band and scrolls when the queue is longer.
                        child: SizedBox(
                          width: double.infinity,
                          height: expanded ? bandHeight : 0,
                          child: expanded ? widget.list : null,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            SizedBox(
              height: scrubberSlotHeight,
              child: widget.scrubber == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: widget.scrubber,
                    ),
            ),
            SizedBox(
              height: transportRowHeight,
              child: widget.transport,
            ),
            const SizedBox(height: _gapBelowTransport),
          ],
        );
      },
    );
  }
}

/// Fixed-height title slot: the item title, centered with a 250ms crossfade
/// between items, and the compact "next station" control on its right edge.
///
/// An invisible square of the control's size balances the left edge (the same
/// ghost trick the transport row uses), so the title stays optically centered
/// instead of drifting left as soon as a control shares its row.
class _TitleSlot extends StatelessWidget {
  const _TitleSlot({
    required this.title,
    required this.onNextStation,
    this.titleKey,
  });

  final String title;
  final Key? titleKey;
  final VoidCallback onNextStation;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kPlaylistTitleSlotHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: Row(
          children: [
            const SizedBox.square(dimension: kPlaylistNextStationControlSize),
            Expanded(
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: Text(
                    title,
                    key: titleKey,
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
            ),
            PlaylistNextStationButton(onPressed: onNextStation),
          ],
        ),
      ),
    );
  }
}

/// Fixed-height publish-date slot — reserved even when the item has no date, so
/// a dated item and an undated one put the transport in the same place.
class _MetaSlot extends StatelessWidget {
  const _MetaSlot({required this.subtitle});

  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final text = subtitle;
    return SizedBox(
      height: kPlaylistMetaSlotHeight,
      child: text == null
          ? null
          : Center(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
    );
  }
}

/// Compact, tappable playlist header: the playing item's title, its position in
/// the list and a chevron that rotates as the list expands.
///
/// Deliberately shaped nothing like the round transport buttons — it is a full
/// width card, so it can never be mistaken for a transport control.
class PlaylistQueueHeader extends StatelessWidget {
  const PlaylistQueueHeader({
    super.key,
    required this.expanded,
    required this.title,
    required this.currentIndex,
    required this.itemCount,
    required this.onTap,
  });

  final bool expanded;
  final String title;
  final int currentIndex;
  final int itemCount;
  final VoidCallback onTap;

  /// "3 din 12" — 1-based, and just the count when the index is unknown.
  String get _counter {
    if (itemCount <= 0) return 'Listă goală';
    if (currentIndex < 0) return '$itemCount elemente';
    return '${currentIndex + 1} din $itemCount';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Listă de redare, $_counter',
      hint: expanded ? 'Atinge pentru a ascunde lista' : 'Atinge pentru a vedea lista',
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          onTap: onTap,
          child: SizedBox(
            height: kPlaylistQueueHeaderHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: Row(
                children: [
                  Icon(Icons.queue_music_rounded,
                      size: 22, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _counter,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    duration: kPlaylistExpandDuration,
                    curve: Curves.fastOutSlowIn,
                    turns: expanded ? 0.5 : 0.0,
                    child: Icon(Icons.expand_more_rounded,
                        size: 24, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact control on the title row that jumps to the NEXT STATION.
///
/// Rides on the title line rather than owning a row of its own, so the space it
/// used to cost goes to the playlist. It is deliberately shaped nothing like
/// the transport's bare round "next item" arrow: a tonal, outlined circle
/// carrying a FORWARD arrow (not a skip glyph), sitting far from the transport
/// cluster — three separate cues that this moves to another station.
class PlaylistNextStationButton extends StatelessWidget {
  const PlaylistNextStationButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Treci la postul următor',
      child: Tooltip(
        message: 'Treci la postul următor',
        // Keeps the 44x44 touch area around the smaller painted circle.
        child: SizedBox.square(
          dimension: kPlaylistNextStationControlSize,
          child: Center(
            child: Material(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
              shape: CircleBorder(
                side: BorderSide(color: scheme.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onPressed,
                child: SizedBox.square(
                  dimension: kPlaylistNextStationCircleSize,
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    size: 17,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
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
    required this.itemFailed,
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

  /// True when the current item is one that failed to play.
  final bool itemFailed;
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
        onPause: audioHandler.pauseFromUser,
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
          // A way OUT of a playback problem — only while there is one. Opens
          // WhatsApp prefilled with what failed, so the user does not have to
          // describe it.
          if (showPlaybackTroubleContact(
            audioOnlyFallback: audioOnlyFallback && !isYoutubeContent,
            itemFailed: itemFailed,
          ))
            Positioned(
              right: 8,
              bottom: 8,
              child: ContactSupportButton(
                uri: playbackIssueSupportUri(
                  stationTitle: station.displayTitle,
                  stationSlug: station.slug,
                  itemTitle: item?.title,
                  streamUrl: item?.url,
                ),
              ),
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
      mainAxisSize: MainAxisSize.min,
      children: [
        // Height-bounded so the whole scrubber (bar + labels) fits the fixed
        // [kPlaylistScrubberSlotHeight] slot that keeps the transport still.
        SizedBox(
          height: kPlaylistSliderHeight,
          child: SliderTheme(
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
/// [AnimatedPlayButton] driven by [playbackStateStream] (the handler's
/// `playbackState`) — for YouTube items the handler forwards to the inline
/// iframe, so that stream stays the one source of truth for icon and action.
///
/// The prev / play / next trio is [PlayerTransportControls], the very same
/// widget (and the very same [computePlayerLayout] metrics) the classic radio
/// full player uses, so the cluster is pixel-identical across station types.
/// Only the repeat / quality / fullscreen extras are playlist-specific.
///
/// Takes streams and callbacks rather than the handler itself so the row (and
/// the layout it sits in) is widget-testable without the audio stack.
class PlaylistTransport extends StatelessWidget {
  const PlaylistTransport({
    super.key,
    required this.playbackStateStream,
    required this.playButtonKey,
    required this.repeatOne,
    required this.onToggleRepeat,
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    required this.onPrevious,
    required this.onNext,
    this.onQuality,
    this.onFullscreen,
  });

  final Stream<PlaybackState> playbackStateStream;
  final GlobalKey<AnimatedPlayButtonState> playButtonKey;

  /// Whether single-item repeat is active (highlights the repeat button).
  final bool repeatOne;

  /// Toggles single-item repeat (leftmost button).
  final VoidCallback onToggleRepeat;

  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onStop;

  /// Previous / next PLAYLIST ITEM (the station-level jump is the labeled
  /// "Postul următor" button below this row).
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  /// Quality picker, shown right of "next" for multi-quality video items.
  final VoidCallback? onQuality;

  /// Fullscreen action shown right of "next" — video items enter the video
  /// player's fullscreen, YouTube items the iframe fullscreen.
  final VoidCallback? onFullscreen;

  /// Icon size of the secondary (repeat / quality / fullscreen) controls.
  /// Deliberately fixed and smaller than the responsive prev/play/next trio,
  /// which they must never crowd out on a narrow phone.
  static const double _secondaryIconSize = 24.0;

  /// Footprint of a secondary control ([_secondaryIconSize] + a 6px ring).
  static const double _secondaryButtonSize = _secondaryIconSize + 12.0;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    // Same metrics the radio full player uses — see [PlayerTransportControls].
    final metrics = playerLayoutOf(context);
    const iconSize = _secondaryIconSize;

    // Left cluster: repeat (always). Right cluster: fullscreen and/or quality.
    // Both sides are padded with invisible ghosts to equal width so the
    // prev/play/next trio stays dead-center regardless of how many secondary
    // controls the current item exposes.
    final leftControls = <Widget>[
      _RoundIconButton(
        icon: Icons.repeat_rounded,
        iconSize: iconSize,
        color: repeatOne ? AppColors.primary : onSurface,
        onTap: onToggleRepeat,
      ),
    ];
    final rightControls = <Widget>[
      if (onFullscreen != null)
        _RoundIconButton(
          icon: Icons.fullscreen_rounded,
          iconSize: iconSize,
          color: onSurface,
          onTap: onFullscreen!,
        ),
      if (onQuality != null)
        _RoundIconButton(
          icon: Icons.high_quality_rounded,
          iconSize: iconSize,
          color: onSurface,
          onTap: onQuality!,
        ),
    ];
    // Balance the two sides with ghosts so the center trio never shifts.
    const ghost = SizedBox.square(dimension: _secondaryButtonSize);
    while (leftControls.length < rightControls.length) {
      leftControls.insert(0, ghost);
    }
    while (rightControls.length < leftControls.length) {
      rightControls.add(ghost);
    }

    return PlayerTransportControls(
      metrics: metrics,
      playbackStateStream: playbackStateStream,
      playButtonKey: playButtonKey,
      onPlay: onPlay,
      onPause: onPause,
      onStop: onStop,
      onPrevious: onPrevious,
      onNext: onNext,
      leading: leftControls,
      trailing: rightControls,
    );
  }
}

/// Round, tappable secondary transport control (repeat / fullscreen / quality):
/// an icon of [iconSize] inside a 6px ring.
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.iconSize,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final double iconSize;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6.0),
        child: Icon(icon, size: iconSize, color: color),
      ),
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
