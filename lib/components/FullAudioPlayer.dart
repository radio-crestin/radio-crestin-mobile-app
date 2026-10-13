import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:like_button/like_button.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/pages/HomePage.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/widgets/share_handler.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/widgets/review_modal.dart';
import 'package:radio_crestin/widgets/song_history_modal.dart';
import '../services/analytics_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:get_it/get_it.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import '../appAudioHandler.dart';
import '../types/Station.dart';
import '../widgets/animated_play_button.dart';
import '../widgets/cast_button.dart';
import '../widgets/player_video_surface.dart';
import '../widgets/playlist_player_section.dart';
import '../widgets/shrink_to_fit_text.dart';
import '../widgets/sleep_timer_button.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/video_overlay_controls.dart';

/// Responsive sizing for the full-screen player, derived from the screen size.
@immutable
class PlayerLayoutMetrics {
  /// Side length of the square station artwork.
  final double thumbSize;

  /// Width of the song info row under the artwork.
  final double infoWidth;

  /// Diameter of the central play/pause control.
  final double playButtonSize;

  /// Size of the play/pause glyph inside it.
  final double playIconSize;

  /// Size of the skip-forward / skip-back glyphs.
  final double skipIconSize;

  /// Horizontal gap between the play control and the skip controls.
  final double skipSpacing;

  const PlayerLayoutMetrics({
    required this.thumbSize,
    required this.infoWidth,
    required this.playButtonSize,
    required this.playIconSize,
    required this.skipIconSize,
    required this.skipSpacing,
  });
}

/// Gap between the screen edges and the song info below the artwork, and
/// the least gap around the artwork itself.
const double _artworkSideMargin = 24.0;

/// Largest share of the screen width the artwork takes: ~280pt on a
/// 402pt-wide phone, so it doesn't crowd the song and the controls.
const double _maxArtworkWidthFraction = 0.7;

/// Smallest artwork, and the floor of every upper `clamp` bound in
/// [computePlayerLayout], which keeps those bounds well-formed.
const double _minArtworkSize = 140.0;

/// Largest artwork, reached on tablets in portrait.
const double _maxArtworkSize = 480.0;

/// Height of the portrait player besides the artwork and the text: drag
/// handle, header, transport, action icons, bottom inset and the gaps
/// between them.
const double _fixedChromeHeight = 300.0;

/// Height of the portrait player text, which grows with the system text
/// size: the song title slot, the artist line and the action labels.
const double _scalableTextHeight = 90.0;

/// Largest text scale the full player follows, about iOS's second
/// accessibility size. The player is one screen that never scrolls, so past
/// this its text stops growing; [computePlayerLayout] budgets up to it.
const double _maxTextScale = 2.0;

/// Largest text scale of the action labels: iOS's largest standard size.
/// Like a tab bar's labels they stay short, so all five keep one size and
/// fit the row on the narrowest phones.
const double _maxActionLabelTextScale = 1.35;

/// Computes the responsive player layout from the current screen size.
///
/// Pure and side-effect free so the sizing math can be unit tested. The
/// artwork takes [_maxArtworkWidthFraction] of the width when the panel is
/// tall enough, otherwise the height the rest of the player leaves, within
/// `[_minArtworkSize, _maxArtworkSize]`. The height left also sizes the
/// transport controls, so short phones get smaller ones. On phones the song
/// info spans the width between the [_artworkSideMargin]s, wider than the
/// artwork, so the title isn't squeezed; on tablets it lines up with the
/// capped artwork.
///
/// Guards the degenerate case where the panel is laid out before the window
/// has real dimensions (`MediaQuery.size == Size.zero`, common on iOS during
/// launch / return-from-background). A width-derived upper bound goes
/// negative there; when it fell below the lower bound, `num.clamp` threw
/// `ArgumentError: Invalid argument(s): 140.0` — the single highest-volume
/// crash in production (PostHog issue 019d8f95…, 1100+ occurrences). Every
/// upper bound is floored at [_minArtworkSize] so `clamp` stays well-formed.
PlayerLayoutMetrics computePlayerLayout({
  required double screenWidth,
  required double screenHeight,
  required double textScale,
}) {
  final scale = textScale.clamp(1.0, _maxTextScale);
  final panelHeight = screenHeight * 0.9;
  final heightForArtwork =
      panelHeight - _fixedChromeHeight - _scalableTextHeight * scale;

  final maxByWidth = (screenWidth - 2 * _artworkSideMargin)
      .clamp(_minArtworkSize, _maxArtworkSize)
      .toDouble();
  final maxByShare = (screenWidth * _maxArtworkWidthFraction)
      .clamp(_minArtworkSize, maxByWidth)
      .toDouble();
  final thumbSize =
      heightForArtwork.clamp(_minArtworkSize, maxByShare).toDouble();

  // Controls shrink with the height left on short screens: t=0 at 230 or
  // less (iPhone SE), t=1 at 350 or more (most phones).
  final t = ((heightForArtwork - 230.0) / 120.0).clamp(0.0, 1.0).toDouble();

  return PlayerLayoutMetrics(
    thumbSize: thumbSize,
    infoWidth: math.max(thumbSize, maxByWidth),
    playButtonSize: 60.0 + 12.0 * t, // 60..72
    playIconSize: 30.0 + 6.0 * t, // 30..36
    skipIconSize: 34.0 + 6.0 * t, // 34..40
    skipSpacing: 24.0 + 12.0 * t, // 24..36
  );
}

class FullAudioPlayer extends StatefulWidget {
  final AppAudioHandler audioHandler;
  final CustomPanelController slidingUpPanelController;

  const FullAudioPlayer({
    super.key,
    required this.audioHandler,
    required this.slidingUpPanelController,
  });

  @override
  _FullAudioPlayerState createState() => _FullAudioPlayerState();
}

class _FullAudioPlayerState extends State<FullAudioPlayer> {
  Station? currentStation;
  bool _isVideoMode = false;
  bool _audioOnlyFallback = false;
  bool _panelExpanded = false;
  final List _subscriptions = [];
  List<String> _favoriteSlugs = [];
  final _playButtonKey = GlobalKey<AnimatedPlayButtonState>();
  // Replaced for every station: LikeButton plays its "liked" burst whenever
  // `isLiked` turns true on a live button, so reusing one would celebrate
  // each favorite that next/previous lands on instead of just showing it.
  var _likeButtonKey = GlobalKey<LikeButtonState>();
  final StationDataService _stationDataService = GetIt.instance<StationDataService>();

  /// Shown under the artwork when a radio station has no song metadata:
  /// the station is on air, only the song title is unknown.
  static const _noMetadataLabel = "Live";

  /// Primary line under the artwork for radio/TV stations: the song title when
  /// one is playing, a "Transmisiune live" label for an idle TV channel, or
  /// [_noMetadataLabel] (so a station never looks blank).
  String _primaryLine() {
    final s = currentStation;
    if (s == null) return _noMetadataLabel;
    if (s.songTitle.isNotEmpty) return s.songTitle;
    return s.isTv ? "Transmisiune live" : _noMetadataLabel;
  }

  @override
  void initState() {
    super.initState();

    // Seeded synchronously so the first frame already shows the right heart,
    // rather than one that fills in (and animates) a frame later.
    _favoriteSlugs = _stationDataService.favoriteStationSlugs.value;
    _subscriptions.add(_stationDataService.favoriteStationSlugs.stream.listen((slugs) {
      if (mounted) {
        setState(() {
          _favoriteSlugs = slugs;
        });
      }
    }));

    currentStation = widget.audioHandler.currentStation.value;
    _subscriptions.add(widget.audioHandler.currentStation.stream.listen((Station? value) {
      if (mounted) {
        setState(() {
          if (value?.slug != currentStation?.slug) {
            _likeButtonKey = GlobalKey<LikeButtonState>();
          }
          currentStation = value;
        });
      }
    }));

    _isVideoMode = widget.audioHandler.isVideoMode.value;
    _subscriptions.add(widget.audioHandler.isVideoMode.stream.listen((value) {
      if (mounted) {
        setState(() {
          _isVideoMode = value;
        });
      }
    }));

    _audioOnlyFallback = widget.audioHandler.audioOnlyFallback.value;
    _subscriptions.add(
        widget.audioHandler.audioOnlyFallback.stream.listen((value) {
      if (mounted) {
        setState(() {
          _audioOnlyFallback = value;
        });
      }
    }));

    // Whether the panel is expanded — gates the inline YouTube surface so it is
    // hidden (but still mounted + playing) while collapsed to the mini player.
    _panelExpanded = widget.slidingUpPanelController.isExpandedSubject.value;
    _subscriptions.add(
        widget.slidingUpPanelController.isExpandedSubject.stream.listen((value) {
      if (mounted) {
        setState(() {
          _panelExpanded = value;
        });
      }
    }));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasYoutubeLink = (currentStation != null &&
        (currentStation!.songArtist.isNotEmpty || currentStation!.songTitle.isNotEmpty));

    // Playlist stations get a dedicated layout (per-item transport + track
    // list) instead of the single-artwork radio layout.
    if (currentStation?.isPlaylist ?? false) {
      return _buildPlaylistPlayer(context);
    }

    // Responsive layout derived from the available screen size. Extracted to a
    // pure, unit-tested function so the sizing math — including the degenerate
    // Size.zero case that used to throw ArgumentError from num.clamp — stays
    // verifiable. See computePlayerLayout above.
    // Aspect-specific lookups so keyboard viewInsets changes (e.g. the search
    // dialog opening above the panel) don't rebuild the player every frame.
    final screen = MediaQuery.sizeOf(context);
    final layout = computePlayerLayout(
      screenWidth: screen.width,
      screenHeight: screen.height,
      textScale: MediaQuery.textScalerOf(context).scale(1.0),
    );

    // In landscape the tall portrait column wastes the wide canvas, so we
    // switch to a TV-style split: artwork on the left, all metadata + controls
    // stacked in a column on the right. Applies to phones and tablets alike;
    // the split itself adapts to the short height of a phone in landscape (see
    // _buildLandscapeLayout). Any portrait orientation keeps the vertical
    // layout untouched.
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (isLandscape) {
      return _buildLandscapeLayout(context, hasYoutubeLink, layout);
    }

    // Under the wider video, the song info spans the side margins instead.
    final infoWidth = _isVideoMode
        ? math.max(screen.width - 2 * _artworkSideMargin, 0.0)
        : layout.infoWidth;

    return _PlayerPanel(
      child: Column(
        children: [
          _buildDragHandle(context),
          const SizedBox(height: 6.0),
          _buildHeader(context),
          // Video mode pulls the media high on the screen ("video dominates
          // the top"); the audio layout lets the artwork breathe.
          _isVideoMode ? const SizedBox(height: 12) : const Spacer(flex: 2),
          // Artwork — crossfades between the station thumbnail and the live
          // video surface (TV stations) when video mode engages.
          _buildArtwork(context, layout.thumbSize),
          const Spacer(flex: 3),
          SizedBox(width: infoWidth, child: _buildSongInfo(context)),
          const Spacer(flex: 4),
          _buildTransportControls(
            context,
            playButtonSize: layout.playButtonSize,
            playIconSize: layout.playIconSize,
            skipIconSize: layout.skipIconSize,
            skipSpacing: layout.skipSpacing,
          ),
          const Spacer(flex: 4),
          _buildBottomActionRow(context, hasYoutubeLink),
          const SizedBox(height: 24.0),
        ],
      ),
    );
  }

  /// Landscape layout: artwork on the left, metadata + controls in a column on
  /// the right (mirrors the TV / Apple TV now-playing screen). Reuses the exact
  /// same content widgets as the portrait layout so behaviour and animations
  /// stay identical — only the arrangement changes.
  ///
  /// Adapts to the caller's height: on a phone in landscape the panel content
  /// is only ~300–360 logical px tall, so a [compact] mode tightens every
  /// vertical gap and derives its own control sizes (the shared
  /// [computePlayerLayout] metrics are tuned for portrait height budgets). The
  /// [SingleChildScrollView] remains as an overflow safety net.
  Widget _buildLandscapeLayout(
    BuildContext context,
    bool hasYoutubeLink,
    PlayerLayoutMetrics layout,
  ) {
    return _PlayerPanel(
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            _buildDragHandle(context),
            const SizedBox(height: 8.0),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 8.0),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Short heights (phone landscape) get the compact
                    // treatment. Tablets in landscape have >=~520px of
                    // content height, so the 380 threshold cleanly separates
                    // the two form factors.
                    final compact = constraints.maxHeight < 380.0;

                    // Left slot dimensions. In video mode the media is 16:9
                    // and must keep the info column at least ~45% of the
                    // width; the audio artwork stays square.
                    final (double slotW, double slotH) = _landscapeMediaSize(
                      maxWidth: constraints.maxWidth,
                      maxHeight: constraints.maxHeight,
                      isVideo: _isVideoMode,
                    );

                    final artGap = compact ? 20.0 : 24.0;

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: slotW,
                          height: slotH,
                          child: Center(child: _buildArtwork(context, slotW)),
                        ),
                        SizedBox(width: artGap),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    _buildCollapseButton(context),
                                    Expanded(
                                      child: _buildStationTitle(context,
                                          textAlign: TextAlign.start),
                                    ),
                                    _buildCastButton(context),
                                  ],
                                ),
                                SizedBox(height: compact ? 6.0 : 12.0),
                                _buildSongInfo(context),
                                SizedBox(height: compact ? 12.0 : 24.0),
                                // Compact phones keep a prominent play button
                                // with modest skips so the cluster fits the
                                // short height; tablets keep the portrait
                                // metrics.
                                _buildTransportControls(
                                  context,
                                  playButtonSize:
                                      compact ? 64.0 : layout.playButtonSize,
                                  playIconSize:
                                      compact ? 32.0 : layout.playIconSize,
                                  skipIconSize:
                                      compact ? 32.0 : layout.skipIconSize,
                                  skipSpacing:
                                      compact ? 24.0 : layout.skipSpacing,
                                  alignStart: true,
                                ),
                                SizedBox(height: compact ? 8.0 : 16.0),
                                _buildBottomActionRow(context, hasYoutubeLink,
                                    alignStart: true),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Size of the landscape left media slot as `(width, height)`.
  ///
  /// Audio artwork is square and fills the available height, capped so the
  /// info column keeps room. Video is 16:9 and capped so the column keeps at
  /// least ~45% of the width. Every `clamp` upper bound is floored at its lower
  /// bound so the math is well-formed even mid-drag / split-screen (see the
  /// crash guard on [computePlayerLayout]).
  (double, double) _landscapeMediaSize({
    required double maxWidth,
    required double maxHeight,
    required bool isVideo,
  }) {
    if (isVideo) {
      // Never let the 16:9 stage swallow more than 55% of the width, so the
      // info column always keeps >=45%.
      final maxVideoWidth =
          (maxWidth * 0.55).clamp(140.0, double.infinity).toDouble();
      var videoH = maxHeight.clamp(120.0, 360.0).toDouble();
      var videoW = videoH * 16.0 / 9.0;
      if (videoW > maxVideoWidth) {
        videoW = maxVideoWidth;
        videoH = videoW * 9.0 / 16.0;
      }
      return (videoW, videoH);
    }

    // Square artwork sized to the row height, but never wider than ~44% of the
    // row so the info column keeps room.
    final maxByWidth =
        (maxWidth * 0.44).clamp(140.0, double.infinity).toDouble();
    final artSize = maxHeight
        .clamp(140.0, 360.0)
        .clamp(140.0, maxByWidth)
        .toDouble();
    return (artSize, artSize);
  }

  /// The rounded drag handle at the top of the sliding panel, as muted as
  /// the sleep sheet's grabber.
  Widget _buildDragHandle(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(top: 3.0),
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface
            .withValues(alpha: isDark ? 0.35 : 0.22),
        borderRadius: const BorderRadius.all(Radius.circular(12.0)),
      ),
    );
  }

  /// The station name between the collapse and cast buttons, which keep it
  /// centered over the artwork. Without [showCast] an empty slot of the same
  /// size takes the cast button's place.
  ///
  /// The buttons' 56pt targets reach to 4pt from the screen edges, so the
  /// icons sit where they did in 48pt targets.
  Widget _buildHeader(BuildContext context, {bool showCast = true}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: Row(
        children: [
          _buildCollapseButton(context),
          Expanded(child: _buildStationTitle(context)),
          showCast
              ? _buildCastButton(context)
              : const SizedBox.square(dimension: PlayerCastButton.size),
        ],
      ),
    );
  }

  /// Slides the panel back down to the mini player.
  Widget _buildCollapseButton(BuildContext context) {
    return SizedBox.square(
      dimension: PlayerCastButton.size,
      child: IconButton(
        tooltip: 'Închide playerul',
        onPressed: () {
          AnalyticsService.instance.capture('button_clicked', {'button_name': 'collapse_player', 'station_id': currentStation?.id, 'station_slug': currentStation?.slug});
          final panel = widget.slidingUpPanelController;
          if (panel.isAttached) panel.close();
        },
        icon: Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 30,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }

  /// Opens the device sheet: Chromecast, AirPlay, TV and car.
  Widget _buildCastButton(BuildContext context) {
    return PlayerCastButton(
      onPressed: () {
        AnalyticsService.instance.capture('button_clicked', {'button_name': 'cast', 'station_id': currentStation?.id, 'station_slug': currentStation?.slug});
        showCastDevicePicker(context, source: 'full_player');
      },
    );
  }

  /// Smallest size of the station name, which never wraps. The longest names
  /// (~28 characters) fit on one line by 16px on a 360pt-wide phone; past
  /// that the name ends in an ellipsis.
  static const double _stationTitleMinFontSize = 16;

  /// The station name, crossfading between stations. A name too long for
  /// 18px shrinks to fit one line, so the header keeps its height and the
  /// artwork below never moves between stations.
  Widget _buildStationTitle(BuildContext context,
      {TextAlign textAlign = TextAlign.center}) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: ShrinkToFitText(
        currentStation?.displayTitle ?? "",
        key: ValueKey('title-${currentStation?.id}'),
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 18,
        ),
        minFontSize: _stationTitleMinFontSize,
        textAlign: textAlign,
      ),
    );
  }

  /// Smallest size of a one-line song title. The title shares its row with
  /// the like / dislike buttons, so one too long for this wraps to two lines
  /// rather than shrinking to a small single line.
  static const double _songTitleMinFontSize = 20;

  /// Smallest size of a song title wrapped to two lines.
  static const double _songTitleTwoLineMinFontSize = 15;

  /// The primary song line, crossfading on change. Its height is fixed: a
  /// title too long for 22px shrinks a little, then wraps to two lines, so
  /// the controls below never shift when the song changes.
  Widget _buildSongTitle(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: ShrinkToFitText(
        _primaryLine(),
        key: ValueKey('song-${currentStation?.songTitle}-${currentStation?.id}'),
        textAlign: TextAlign.start,
        minFontSize: _songTitleMinFontSize,
        twoLineMinFontSize: _songTitleTwoLineMinFontSize,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// The song artist line, crossfading on change.
  Widget _buildArtist(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      // Full width, so the outgoing and incoming names share a start edge
      // while they crossfade.
      child: Align(
        key: ValueKey('artist-${currentStation?.songArtist}-${currentStation?.id}'),
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          currentStation?.songArtist ?? "",
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            color: Theme.of(context).textSecondary,
          ),
        ),
      ),
    );
  }

  /// The song title and artist, with the like / dislike buttons on their
  /// right.
  Widget _buildSongInfo(BuildContext context) {
    final songId = currentStation?.songId ?? -1;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildSongTitle(context),
              const SizedBox(height: 4),
              _buildArtist(context),
            ],
          ),
        ),
        const SizedBox(width: 16),
        _RatingButtons(
          likeStatus: GetIt.instance<SongLikeService>().getLikeStatus(songId),
          onLike: () {
            AnalyticsService.instance.capture('button_clicked', {'button_name': 'like_song', 'station_id': currentStation?.id, 'station_slug': currentStation?.slug, 'song_id': currentStation?.songId});
            _showReviewModal(context, initialStars: 5);
          },
          onDislike: () {
            AnalyticsService.instance.capture('button_clicked', {'button_name': 'dislike_song', 'station_id': currentStation?.id, 'station_slug': currentStation?.slug, 'song_id': currentStation?.songId});
            _showReviewModal(context, initialStars: 1);
          },
        ),
      ],
    );
  }

  /// Transport controls: prev | play/pause | next. [alignStart] left-aligns the
  /// cluster for the landscape right-hand column.
  Widget _buildTransportControls(
    BuildContext context, {
    required double playButtonSize,
    required double playIconSize,
    required double skipIconSize,
    required double skipSpacing,
    bool alignStart = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final skipColor = Theme.of(context).colorScheme.onSurface;
    return Row(
      mainAxisAlignment:
          alignStart ? MainAxisAlignment.start : MainAxisAlignment.center,
      children: <Widget>[
        IconButton(
          tooltip: 'Stația anterioară',
          iconSize: skipIconSize,
          color: skipColor,
          onPressed: () {
            _playButtonKey.currentState?.notifyWillPlay();
            widget.audioHandler.skipToPrevious();
          },
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        SizedBox(width: skipSpacing),
        // The brand pink disc, lifted by a soft glow of the same pink.
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color:
                    AppColors.primary.withValues(alpha: isDark ? 0.45 : 0.35),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: AnimatedPlayButton(
            key: _playButtonKey,
            playbackStateStream: widget.audioHandler.playbackState,
            size: playButtonSize,
            iconSize: playIconSize,
            iconColor: Colors.white,
            backgroundColor: AppColors.primary,
            onPlay: widget.audioHandler.play,
            onPause: widget.audioHandler.pause,
            onStop: widget.audioHandler.stop,
          ),
        ),
        SizedBox(width: skipSpacing),
        IconButton(
          tooltip: 'Stația următoare',
          iconSize: skipIconSize,
          color: skipColor,
          onPressed: () {
            _playButtonKey.currentState?.notifyWillPlay();
            widget.audioHandler.skipToNext();
          },
          icon: const Icon(Icons.skip_next_rounded),
        ),
      ],
    );
  }

  /// Bottom action row: favorit | somn | istoric | youtube | trimite.
  /// Portrait gives each action an equal share of the width; [alignStart]
  /// packs them at the start of the landscape right-hand column instead.
  Widget _buildBottomActionRow(BuildContext context, bool hasYoutubeLink,
      {bool alignStart = false}) {
    final actions = <Widget>[
      _buildFavoriteButton(context),
      SleepTimerButton(
        service: widget.audioHandler.sleepTimer,
        onTap: () {
          AnalyticsService.instance.capture('button_clicked', {'button_name': 'sleep_timer', 'station_id': currentStation?.id, 'station_slug': currentStation?.slug});
          _showSleepTimerSheet(context);
        },
      ),
      _buildActionButton(
        context,
        icon: Icons.history,
        label: 'istoric',
        onTap: () {
          AnalyticsService.instance.capture('button_clicked', {'button_name': 'song_history', 'station_id': currentStation?.id, 'station_slug': currentStation?.slug});
          final station = currentStation;
          if (station != null) {
            SongHistoryModal.show(
              context,
              stationSlug: station.slug,
              stationTitle: station.title,
              stationThumbnailUrl: station.thumbnailUrl,
              playedCutoff: () =>
                  _stationDataService.playedCutoffFor(station.id),
            );
          }
        },
      ),
      _buildActionButton(
        context,
        icon: Icons.video_collection,
        label: 'youtube',
        isEnabled: hasYoutubeLink,
        onTap: () async {
          if (!hasYoutubeLink || currentStation == null) return;
          AnalyticsService.instance.capture('button_clicked', {'button_name': 'youtube_search', 'station_id': currentStation?.id, 'station_slug': currentStation?.slug, 'song_id': currentStation?.songId, 'song_title': currentStation?.songTitle});
          final query = "${currentStation?.songArtist} - ${currentStation?.songTitle}";
          final encodedQuery = Uri.encodeQueryComponent(query);
          final searchUrl = 'https://www.youtube.com/results?q=$encodedQuery';
          await launchUrl(Uri.parse(searchUrl), mode: LaunchMode.externalApplication);
        },
      ),
      _buildActionButton(
        context,
        icon: Icons.share_outlined,
        label: 'trimite',
        onTap: () {
          AnalyticsService.instance.capture('button_clicked', {'button_name': 'share', 'station_id': currentStation?.id, 'station_slug': currentStation?.slug, 'song_id': currentStation?.songId});
          _showShareDialog(context);
        },
      ),
    ];

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: _maxActionLabelTextScale,
      child: alignStart
          // Scales down rather than overflowing a narrow column.
          ? FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            )
          // On tablets the row spans no wider than the largest artwork and
          // its margins, so the actions stay close together.
          : ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: _maxArtworkSize + 2 * _artworkSideMargin,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Row(
                  children: [
                    for (final action in actions) Expanded(child: action),
                  ],
                ),
              ),
            ),
    );
  }

  /// The favorite toggle, which bursts into bubbles when favoriting.
  Widget _buildFavoriteButton(BuildContext context) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () {
        AnalyticsService.instance.capture('button_clicked', {'button_name': 'favorite', 'station_id': currentStation?.id, 'station_slug': currentStation?.slug});
        _likeButtonKey.currentState?.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IgnorePointer(
              // Sized like the other actions' icons so the labels line up;
              // the bubbles overflow it.
              child: LikeButton(
                key: _likeButtonKey,
                size: 24,
                bubblesSize: 30,
                isLiked: currentStation != null && _favoriteSlugs.contains(currentStation!.slug),
                likeBuilder: (bool isLiked) {
                  return Icon(
                    isLiked ? Icons.favorite_sharp : Icons.favorite_border_sharp,
                    color: isLiked
                        ? Theme.of(context).primaryColor
                        : Theme.of(context).colorScheme.onSurface,
                    size: 23,
                  );
                },
                onTap: (bool isLiked) async {
                  if (currentStation != null) {
                    widget.audioHandler.setStationIsFavorite(currentStation!, !isLiked);
                  }
                  return !isLiked;
                },
              ),
            ),
            const _ActionLabel('favorit'),
          ],
        ),
      ),
    );
  }

  /// Crossfades between the square station thumbnail and a 16:9 live video
  /// surface (for TV stations in video mode).
  Widget _buildArtwork(BuildContext context, double thumbSize) {
    if (_isVideoMode) {
      // Big, edge-to-edge (minus a ~12px margin) 16:9 video with the
      // YouTube-style overlay controls. TV channels are live, so the overlay
      // shows the LIVE pill and no scrubber.
      final isLive = currentStation?.isTv ?? false;
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: Padding(
          key: const ValueKey('player-video-surface'),
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: VideoPlayerStage(
              videoService: widget.audioHandler.videoService,
              title: currentStation?.displayTitle ?? '',
              isLive: isLive,
              showTransport: false,
              onPlay: widget.audioHandler.play,
              onPause: widget.audioHandler.pause,
              onSeek: isLive ? null : widget.audioHandler.seek,
            ),
          ),
        ),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Decoded, and fetched from the image CDN, at the size it is drawn, so
    // the artwork stays sharp on 3x screens.
    final pixels = (thumbSize * MediaQuery.devicePixelRatioOf(context)).ceil();
    final artwork = AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: Container(
        key: ValueKey('thumb-${currentStation?.id}-${currentStation?.songId}'),
        width: thumbSize,
        height: thumbSize,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius:
              const BorderRadius.all(Radius.circular(AppRadius.artwork)),
          boxShadow: isDark
              // Soft brand-pink glow that lifts the artwork off the panel.
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.28),
                    blurRadius: 40,
                    offset: const Offset(0, 16),
                  ),
                ]
              // The pink comes from the backlight; a hairline and a soft
              // shadow keep white logos from melting into it.
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    spreadRadius: 1,
                  ),
                  BoxShadow(
                    color: AppColors.primaryDark.withValues(alpha: 0.16),
                    blurRadius: 28,
                    offset: const Offset(0, 14),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius:
              const BorderRadius.all(Radius.circular(AppRadius.artwork)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (currentStation != null)
                currentStation!.displayThumbnail(
                  cacheWidth: pixels,
                  sourceWidth: pixels,
                ),
              // "Doar audio" chip when a TV channel's video couldn't render and
              // playback fell back to audio-only.
              if (_audioOnlyFallback)
                const Positioned(
                  top: 8,
                  left: 8,
                  child: AudioOnlyChip(),
                ),
            ],
          ),
        ),
      ),
    );
    if (isDark) return artwork;
    // Outside the switcher, so the light holds steady while the artwork
    // crossfades over it.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Positioned.fill(child: _ArtworkBacklight()),
        artwork,
      ],
    );
  }

  /// Full player layout for playlist stations: header + [PlaylistPlayerSection]
  /// (media surface, scrubber, transport, track list) + a slim action row.
  Widget _buildPlaylistPlayer(BuildContext context) {
    final station = currentStation!;
    final isFavorite = _favoriteSlugs.contains(station.slug);
    return _PlayerPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildDragHandle(context),
          const SizedBox(height: 6.0),
          _buildHeader(context, showCast: false),
          const SizedBox(height: 4),
          Expanded(
            child: PlaylistPlayerSection(
              audioHandler: widget.audioHandler,
              station: station,
              panelExpanded: _panelExpanded,
            ),
          ),
          // Slim action row: favorite | share | sleep.
          MediaQuery.withClampedTextScaling(
            maxScaleFactor: _maxActionLabelTextScale,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    AnalyticsService.instance.capture('button_clicked', {
                      'button_name': 'favorite',
                      'station_id': station.id,
                      'station_slug': station.slug,
                    });
                    widget.audioHandler
                        .setStationIsFavorite(station, !isFavorite);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(10.0),
                    child: Column(
                      children: [
                        Icon(
                          isFavorite
                              ? Icons.favorite_sharp
                              : Icons.favorite_border_sharp,
                          size: 23,
                          color: isFavorite
                              ? Theme.of(context).primaryColor
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                        const _ActionLabel('favorit'),
                      ],
                    ),
                  ),
                ),
                _buildActionButton(
                  context,
                  icon: Icons.share_outlined,
                  label: 'trimite',
                  onTap: () {
                    AnalyticsService.instance.capture('button_clicked', {
                      'button_name': 'share',
                      'station_id': station.id,
                      'station_slug': station.slug,
                    });
                    _showShareDialog(context);
                  },
                ),
                SleepTimerButton(
                  service: widget.audioHandler.sleepTimer,
                  onTap: () {
                    AnalyticsService.instance.capture('button_clicked', {
                      'button_name': 'sleep_timer',
                      'station_id': station.id,
                      'station_slug': station.slug,
                    });
                    _showSleepTimerSheet(context);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24.0),
        ],
      ),
    );
  }

  /// An icon over its label, for the action rows at the bottom.
  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isEnabled = true,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: isEnabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: isEnabled
                  ? theme.colorScheme.onSurface
                  : theme.disabledColor,
            ),
            _ActionLabel(label, color: isEnabled ? null : theme.disabledColor),
          ],
        ),
      ),
    );
  }

  void _showReviewModal(BuildContext context, {required int initialStars}) async {
    if (currentStation == null) return;
    final songId = currentStation!.songId;
    final likeService = GetIt.instance<SongLikeService>();
    final currentStatus = likeService.getLikeStatus(songId);
    // Check if this tap is removing an existing like/dislike
    final isRemoving = (initialStars >= 4 && currentStatus == 1) ||
        (initialStars < 4 && currentStatus == -1);
    // Toggle the like/dislike status
    if (initialStars >= 4) {
      await widget.audioHandler.customAction('likeSong');
    } else {
      await widget.audioHandler.customAction('dislikeSong');
    }
    if (mounted) setState(() {});
    // Only show review modal when adding, not when removing
    if (isRemoving) return;
    if (!context.mounted) return;
    ReviewModal.show(
      context,
      stationId: currentStation!.id,
      stationTitle: currentStation!.title,
      songId: currentStation!.songId,
      songTitle: currentStation!.songTitle,
      songArtist: currentStation!.songArtist,
      initialStars: initialStars,
    );
  }

  void _showShareDialog(BuildContext context) {
    final slug = currentStation?.slug;
    final shareUrl = slug != null && slug.isNotEmpty
        ? 'https://www.radiocrestin.ro/$slug'
        : 'https://www.radiocrestin.ro/descarca-aplicatia-radio-crestin';

    ShareHandler.shareApp(
      context: context,
      shareUrl: shareUrl,
      shareMessage: 'Instalează și tu aplicația Radio Creștin și ascultă peste 60 de stații de radio creștin:\n$shareUrl',
      stationName: currentStation?.title,
      songName: currentStation?.songTitle,
      songArtist: currentStation?.songArtist,
      songId: currentStation?.songId,
      showDialog: true,
      shareLinkLoader: () async {
        final prefs = await SharedPreferences.getInstance();
        final deviceId = prefs.getString('device_id');
        if (deviceId == null) return null;
        final shareService = ShareService(widget.audioHandler.graphqlClient);
        return shareService.getShareLink(deviceId);
      },
    );
  }

  /// Opens the sleep timer sheet.
  void _showSleepTimerSheet(BuildContext context) {
    SleepTimerSheet.show(
      context,
      service: widget.audioHandler.sleepTimer,
      onDurationChosen: (duration) => AnalyticsService.instance.capture(
        'button_clicked',
        {
          'button_name': 'sleep_timer_set',
          'duration_minutes': duration.inMinutes,
        },
      ),
      onCancelled: () => AnalyticsService.instance.capture(
        'button_clicked',
        {'button_name': 'sleep_timer_cancel'},
      ),
    );
  }
}

/// A soft brand-pink light behind the artwork in the light theme, where a
/// pink shadow would fade into the pale panel.
///
/// Fills the artwork's box and is stretched past it into an ellipse: wide
/// enough in portrait to reach the screen edges, rounder in landscape so it
/// stays out from under the info column.
class _ArtworkBacklight extends StatelessWidget {
  const _ArtworkBacklight();

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return IgnorePointer(
      child: Transform.scale(
        scaleX: isLandscape ? 1.6 : 2.2,
        scaleY: 1.36,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [
                AppColors.primary.withValues(alpha: 0.36),
                AppColors.primary.withValues(alpha: 0.18),
                AppColors.primaryLight.withValues(alpha: 0.07),
                AppColors.primaryLight.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.45, 0.75, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}

/// The sliding panel's background: rounded top corners over the brand
/// gradient in the dark theme, and over white fading into the page in the
/// light theme, where the pink comes from the [_ArtworkBacklight] instead.
///
/// A transparent [Material] sits above the gradient so the buttons' ripples
/// show: an [InkWell] paints on its nearest Material, which would otherwise
/// be the page under the panel, covered by the gradient.
class _PlayerPanel extends StatelessWidget {
  const _PlayerPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = theme.scaffoldBackgroundColor;
    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16.0),
          topRight: Radius.circular(16.0),
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [
                  const Color(0xFF2C1018),
                  const Color(0xFF1A0A0F),
                  bgColor,
                ]
              : [Colors.white, bgColor],
          stops: isDark ? const [0.0, 0.35, 0.7] : const [0.0, 0.6],
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: _maxTextScale,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The like / dislike buttons for the playing song, joined into one pill.
class _RatingButtons extends StatelessWidget {
  const _RatingButtons({
    required this.likeStatus,
    required this.onLike,
    required this.onDislike,
  });

  /// 1 liked, -1 disliked, 0 neither (see [SongLikeService.getLikeStatus]).
  final int likeStatus;
  final VoidCallback onLike;
  final VoidCallback onDislike;

  static const _outerRadius = Radius.circular(24);
  static const _innerRadius = Radius.circular(6);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RatingButton(
          icon: Icons.thumb_up_outlined,
          activeIcon: Icons.thumb_up,
          label: 'Îmi place',
          isActive: likeStatus == 1,
          borderRadius: const BorderRadius.horizontal(
            left: _outerRadius,
            right: _innerRadius,
          ),
          onTap: onLike,
        ),
        const SizedBox(width: 2),
        _RatingButton(
          icon: Icons.thumb_down_outlined,
          activeIcon: Icons.thumb_down,
          label: 'Nu-mi place',
          isActive: likeStatus == -1,
          borderRadius: const BorderRadius.horizontal(
            left: _innerRadius,
            right: _outerRadius,
          ),
          onTap: onDislike,
        ),
      ],
    );
  }
}

/// One half of [_RatingButtons]. A quiet tint of the text color at rest; the
/// chosen half brightens a step and fills its icon.
class _RatingButton extends StatelessWidget {
  const _RatingButton({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.borderRadius,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final BorderRadius borderRadius;
  final VoidCallback onTap;

  /// Side length of the square tap target.
  static const double _size = 48;

  @override
  Widget build(BuildContext context) {
    // White on the dark panel, black on the light one; the resting icon
    // keeps over 5:1 against the panel either way.
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final fill = onSurface.withValues(alpha: isActive ? 0.2 : 0.08);
    final iconColor = isActive ? onSurface : onSurface.withValues(alpha: 0.6);

    return Semantics(
      button: true,
      toggled: isActive,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeInOut,
        width: _size,
        height: _size,
        decoration: BoxDecoration(color: fill, borderRadius: borderRadius),
        // The ripple paints on this Material, above the fill.
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: borderRadius,
            onTap: onTap,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: Icon(
                isActive ? activeIcon : icon,
                key: ValueKey(isActive),
                size: 22,
                color: iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small label under a player action's icon. Scales down rather than
/// wrapping when its share of the action row is too narrow.
class _ActionLabel extends StatelessWidget {
  const _ActionLabel(this.text, {this.color});

  final String text;

  /// The theme's secondary text color when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          text,
          maxLines: 1,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: color ?? Theme.of(context).textSecondary,
          ),
        ),
      ),
    );
  }
}
