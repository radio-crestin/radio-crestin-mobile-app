import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:like_button/like_button.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/pages/HomePage.dart';
import 'package:radio_crestin/widgets/share_sheet.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/widgets/review_modal.dart';
import 'package:radio_crestin/widgets/song_history_modal.dart';
import '../services/analytics_service.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:get_it/get_it.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import '../appAudioHandler.dart';
import '../types/Station.dart';
import '../widgets/animated_play_button.dart';
import '../widgets/cast_button.dart';
import '../widgets/copied_toast.dart';
import '../widgets/panel_drag_region.dart';
import '../widgets/player_video_surface.dart';
import '../widgets/playlist_player_section.dart';
import '../widgets/shrink_to_fit_text.dart';
import '../widgets/sleep_timer_button.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/song_actions_button.dart';
import '../widgets/song_search_tip.dart';
import '../widgets/video_overlay_controls.dart';

/// Responsive sizing for the full-screen player, derived from the screen size.
@immutable
class PlayerLayoutMetrics {
  /// Side length of the square station artwork.
  final double thumbSize;

  /// Width of the song info row under the artwork.
  final double infoWidth;

  /// Size of the play/pause glyph; its round tap target is 16 wider.
  final double playIconSize;

  /// Size of the skip-forward / skip-back glyphs.
  final double skipIconSize;

  /// Horizontal gap between the play control and the skip controls.
  final double skipSpacing;

  const PlayerLayoutMetrics({
    required this.thumbSize,
    required this.infoWidth,
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
/// Like a tab bar's labels they stay short, so all four keep one size and
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
    playIconSize: 48.0 + 14.0 * t, // 48..62
    // The rewind / fast-forward glyphs fill less of their box than play's,
    // so they take a larger size to look as bold.
    skipIconSize: 40.0 + 8.0 * t, // 40..48
    // Without a disc behind play, the glyphs need the extra air.
    skipSpacing: 28.0 + 16.0 * t, // 28..44
  );
}

/// The song as copied to the clipboard: "title - artist".
String songClipboardText({required String title, required String artist}) =>
    _joinSongParts([title, artist]);

/// The YouTube search for the song: "artist - title".
String songSearchQuery({required String title, required String artist}) =>
    _joinSongParts([artist, title]);

/// Joins only the parts the station named, so a song without an artist
/// isn't "title - ".
String _joinSongParts(List<String> parts) =>
    parts.where((part) => part.isNotEmpty).join(' - ');

class FullAudioPlayer extends StatefulWidget {
  final AppAudioHandler audioHandler;
  final CustomPanelController slidingUpPanelController;

  /// Room the content keeps clear of at the panel's bottom, which the
  /// backdrop still fills: the panel runs to the screen's edge, behind the
  /// home indicator or the navigation bar.
  final double bottomInset;

  /// How far the panel slides between closed and open, so a drag the player
  /// passes on to the panel moves it with the finger.
  final double panelTravel;

  const FullAudioPlayer({
    super.key,
    required this.audioHandler,
    required this.slidingUpPanelController,
    required this.panelTravel,
    this.bottomInset = 0.0,
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
  // Lets the copy confirmation rise just above the bottom action row.
  final _actionRowKey = GlobalKey();
  // Replaced for every station: LikeButton plays its "liked" burst whenever
  // `isLiked` turns true on a live button, so reusing one would celebrate
  // each favorite that next/previous lands on instead of just showing it.
  // Also replaced when the station leaves the favorites, so a burst still
  // playing stops instead of going on around the empty heart.
  Key _likeButtonKey = UniqueKey();
  final StationDataService _stationDataService = GetIt.instance<StationDataService>();

  /// Whether the tip that a tap on the song searches YouTube is due (see
  /// [SongSearchTipMemory.isDue]). False until the preferences are read, so
  /// the tip never flashes for someone who already dismissed it.
  bool _songSearchTipDue = false;

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

  /// Whether the station named its song, so a YouTube search can find it.
  bool get _hasSong {
    final s = currentStation;
    return s != null && (s.songTitle.isNotEmpty || s.songArtist.isNotEmpty);
  }

  /// The song search tip shows over the open player, while a song is named
  /// (a tap on "Live" does nothing) and the artwork, not a video, is above.
  bool get _showSongSearchTip =>
      _songSearchTipDue && _panelExpanded && _hasSong && !_isVideoMode;

  /// Reads whether the song search tip is due.
  Future<void> _checkSongSearchTip() async {
    final due = await SongSearchTipMemory.isDue();
    if (mounted && due != _songSearchTipDue) {
      setState(() => _songSearchTipDue = due);
    }
  }

  /// Hides the song search tip for good. Also called for a search made
  /// before the tip ever showed: whoever found the search needs no tip.
  void _dismissSongSearchTip() {
    if (_songSearchTipDue) setState(() => _songSearchTipDue = false);
    SongSearchTipMemory.markSeen();
  }

  @override
  void initState() {
    super.initState();

    _checkSongSearchTip();

    // Seeded synchronously so the first frame already shows the right heart,
    // rather than one that fills in (and animates) a frame later.
    _favoriteSlugs = _stationDataService.favoriteStationSlugs.value;
    _subscriptions.add(_stationDataService.favoriteStationSlugs.stream.listen((slugs) {
      if (mounted) {
        setState(() {
          final slug = currentStation?.slug;
          if (slug != null &&
              _favoriteSlugs.contains(slug) &&
              !slugs.contains(slug)) {
            _likeButtonKey = UniqueKey();
          }
          _favoriteSlugs = slugs;
        });
      }
    }));

    currentStation = widget.audioHandler.currentStation.value;
    _subscriptions.add(widget.audioHandler.currentStation.stream.listen((Station? value) {
      if (mounted) {
        final stationChanged = value?.slug != currentStation?.slug;
        setState(() {
          if (stationChanged) {
            _likeButtonKey = UniqueKey();
          }
          currentStation = value;
        });
        // Starting a station is one of the actions that make the tip due,
        // so it can come due as the player shows the new station.
        if (stationChanged && !_songSearchTipDue) _checkSongSearchTip();
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
        // The actions made since the last check, such as starting the
        // station now playing, can have made the tip due.
        if (value && !_songSearchTipDue) _checkSongSearchTip();
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
      return _buildLandscapeLayout(context, layout);
    }

    // Under the wider video, the song info spans the side margins instead.
    final infoWidth = _isVideoMode
        ? math.max(screen.width - 2 * _artworkSideMargin, 0.0)
        : layout.infoWidth;

    return _PlayerPanel(
      bottomInset: widget.bottomInset,
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
            playIconSize: layout.playIconSize,
            skipIconSize: layout.skipIconSize,
            skipSpacing: layout.skipSpacing,
          ),
          const Spacer(flex: 4),
          _buildBottomActionRow(context),
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
    PlayerLayoutMetrics layout,
  ) {
    return _PlayerPanel(
      bottomInset: widget.bottomInset,
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
                                  playIconSize:
                                      compact ? 60.0 : layout.playIconSize,
                                  skipIconSize:
                                      compact ? 32.0 : layout.skipIconSize,
                                  skipSpacing:
                                      compact ? 24.0 : layout.skipSpacing,
                                  alignStart: true,
                                ),
                                SizedBox(height: compact ? 8.0 : 16.0),
                                _buildBottomActionRow(context,
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

  /// The station name with the cast button on its right. An empty slot of
  /// the button's size on the left keeps the name centered over the
  /// artwork; without [showCast] a second one takes the button's place.
  ///
  /// The button's 56pt target reaches to 4pt from the screen edge, so the
  /// icon sits where it did in a 48pt target.
  Widget _buildHeader(BuildContext context, {bool showCast = true}) {
    const slot = SizedBox.square(dimension: PlayerCastButton.size);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: Row(
        children: [
          slot,
          Expanded(child: _buildStationTitle(context)),
          showCast ? _buildCastButton(context) : slot,
        ],
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
  /// right. A tap on the song searches YouTube for it and a long press
  /// opens a menu to copy it or search for it; with no song named ("Live")
  /// the text is not a button.
  Widget _buildSongInfo(BuildContext context) {
    final songId = currentStation?.songId ?? -1;
    return Row(
      children: [
        Expanded(
          child: SongSearchTip(
            visible: _showSongSearchTip,
            onDismiss: _dismissSongSearchTip,
            child: PanelDragRegion(
              controller: widget.slidingUpPanelController,
              travel: widget.panelTravel,
              child: SongActionsButton(
                onSearch: _hasSong ? _searchSongOnYoutube : null,
                onCopy: _hasSong ? _copySong : null,
                onMenuOpened: _trackSongMenuOpened,
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
            ),
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

  /// Transport controls: prev | play/pause | next, as bare glyphs in the
  /// text color, the way Apple Music shows them. [alignStart] left-aligns the
  /// cluster for the landscape right-hand column. Skipping leaves the song
  /// search tip up, for the next station's song.
  Widget _buildTransportControls(
    BuildContext context, {
    required double playIconSize,
    required double skipIconSize,
    required double skipSpacing,
    bool alignStart = false,
  }) {
    final glyphColor = Theme.of(context).colorScheme.onSurface;
    return Row(
      mainAxisAlignment:
          alignStart ? MainAxisAlignment.start : MainAxisAlignment.center,
      children: <Widget>[
        SongSearchTipTapRegion(
          child: IconButton(
            tooltip: 'Stația anterioară',
            iconSize: skipIconSize,
            color: glyphColor,
            onPressed: () {
              _playButtonKey.currentState?.notifyWillPlay();
              widget.audioHandler.skipToPrevious();
            },
            icon: const Icon(Icons.fast_rewind_rounded),
          ),
        ),
        SizedBox(width: skipSpacing),
        AnimatedPlayButton(
          key: _playButtonKey,
          playbackStateStream: widget.audioHandler.playbackState,
          iconSize: playIconSize,
          iconColor: glyphColor,
          onPlay: widget.audioHandler.play,
          onPause: widget.audioHandler.pause,
        ),
        SizedBox(width: skipSpacing),
        SongSearchTipTapRegion(
          child: IconButton(
            tooltip: 'Stația următoare',
            iconSize: skipIconSize,
            color: glyphColor,
            onPressed: () {
              _playButtonKey.currentState?.notifyWillPlay();
              widget.audioHandler.skipToNext();
            },
            icon: const Icon(Icons.fast_forward_rounded),
          ),
        ),
      ],
    );
  }

  /// Bottom action row: favorit | somn | trimite | istoric.
  /// Portrait gives each action an equal share of the width; [alignStart]
  /// packs them at the start of the landscape right-hand column instead.
  Widget _buildBottomActionRow(BuildContext context,
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
        icon: _shareIcon(context),
        label: 'trimite',
        onTap: () {
          AnalyticsService.instance.capture('button_clicked', {'button_name': 'share', 'station_id': currentStation?.id, 'station_slug': currentStation?.slug, 'song_id': currentStation?.songId});
          _showShareSheet(context);
        },
      ),
      _buildActionButton(
        context,
        icon: Icons.history,
        label: 'istoric',
        onTap: () => _showSongHistory(context),
      ),
    ];

    // Keyed here: withClampedTextScaling drops the key it is given.
    return KeyedSubtree(
      key: _actionRowKey,
      child: MediaQuery.withClampedTextScaling(
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
      ),
    );
  }

  /// The favorite toggle, which bursts into bubbles when favoriting.
  ///
  /// The tap goes to the handler, not to `LikeButton`, which ignores taps
  /// while it animates (up to a second): every tap flips the favorite, so
  /// a second one undoes the first at once. `LikeButton` only draws it.
  Widget _buildFavoriteButton(BuildContext context) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () {
        final station = currentStation;
        if (station == null) return;
        AnalyticsService.instance.capture('button_clicked', {'button_name': 'favorite', 'station_id': station.id, 'station_slug': station.slug});
        widget.audioHandler.toggleStationFavorite(station);
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

    // Decoded, and fetched from the image CDN, at the size it is drawn, so
    // the artwork stays sharp on 3x screens.
    final pixels = (thumbSize * MediaQuery.devicePixelRatioOf(context)).ceil();
    return AnimatedSwitcher(
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
  }

  /// Full player layout for playlist stations: header + [PlaylistPlayerSection]
  /// (media surface, scrubber, transport, track list) + a slim action row.
  Widget _buildPlaylistPlayer(BuildContext context) {
    final station = currentStation!;
    final isFavorite = _favoriteSlugs.contains(station.slug);
    return _PlayerPanel(
      bottomInset: widget.bottomInset,
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
                    widget.audioHandler.toggleStationFavorite(station);
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
                  icon: _shareIcon(context),
                  label: 'trimite',
                  onTap: () {
                    AnalyticsService.instance.capture('button_clicked', {
                      'button_name': 'share',
                      'station_id': station.id,
                      'station_slug': station.slug,
                    });
                    _showShareSheet(context);
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

  /// The platform's own share icon: the square with an arrow on iOS, the
  /// three linked dots on Android.
  IconData _shareIcon(BuildContext context) =>
      switch (Theme.of(context).platform) {
        TargetPlatform.iOS || TargetPlatform.macOS => CupertinoIcons.share,
        _ => Icons.share_outlined,
      };

  /// An icon over its label, for the action rows at the bottom.
  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: Theme.of(context).colorScheme.onSurface),
            _ActionLabel(label),
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

  /// Opens the sheet that invites a friend to the current station.
  void _showShareSheet(BuildContext context) {
    ShareSheet.showForStation(
      context,
      station: currentStation,
      client: widget.audioHandler.graphqlClient,
    );
  }

  /// Opens the songs the current station played lately.
  void _showSongHistory(BuildContext context) {
    final station = currentStation;
    if (station == null) return;
    AnalyticsService.instance.capture('button_clicked', {'button_name': 'song_history', 'station_id': station.id, 'station_slug': station.slug});
    SongHistoryModal.show(
      context,
      stationSlug: station.slug,
      stationThumbnailUrl: station.thumbnailUrl,
      playedCutoff: () => _stationDataService.playedCutoffFor(station.id),
    );
  }

  /// Searches YouTube for the playing song, in the YouTube app when it is
  /// installed.
  Future<void> _searchSongOnYoutube() async {
    final station = currentStation;
    if (station == null) return;
    // Using the search is the lesson the tip teaches.
    _dismissSongSearchTip();
    AnalyticsService.instance.capture('button_clicked', {'button_name': 'youtube_search', 'station_id': station.id, 'station_slug': station.slug, 'song_id': station.songId, 'song_title': station.songTitle});
    final query = Uri.encodeQueryComponent(
      songSearchQuery(title: station.songTitle, artist: station.songArtist),
    );
    try {
      await launchUrl(
        Uri.parse('https://www.youtube.com/results?q=$query'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // Neither the YouTube app nor a browser could take the link; nothing
      // else to offer from here.
    }
  }

  void _trackSongMenuOpened() {
    AnalyticsService.instance.capture('button_clicked', {'button_name': 'song_menu', 'station_id': currentStation?.id, 'station_slug': currentStation?.slug, 'song_id': currentStation?.songId});
  }

  /// Copies the playing song as "title - artist", with the platform's
  /// success haptic, and confirms it on screen unless the system already
  /// does.
  ///
  /// No sound: neither platform plays one for a copy, and it would land on
  /// top of the station the user is listening to.
  Future<void> _copySong() async {
    final station = currentStation;
    if (station == null) return;
    AnalyticsService.instance.capture('button_clicked', {'button_name': 'copy_song', 'station_id': station.id, 'station_slug': station.slug, 'song_id': station.songId, 'song_title': station.songTitle});
    try {
      await Clipboard.setData(ClipboardData(
        text: songClipboardText(
          title: station.songTitle,
          artist: station.songArtist,
        ),
      ));
    } catch (_) {
      return;
    }
    HapticFeedback.successNotification();
    if (await _systemConfirmsCopies() || !mounted) return;
    CopiedToast.show(
      context,
      message: 'Melodie copiată',
      bottom: _aboveActionRow(),
    );
  }

  /// How far above the screen's bottom edge a toast clears the bottom
  /// action row, so it never covers those buttons; null if the row isn't
  /// laid out.
  double? _aboveActionRow() {
    final row = _actionRowKey.currentContext?.findRenderObject();
    if (row is! RenderBox || !row.hasSize) return null;
    final rowTop = row.localToGlobal(Offset.zero).dy;
    return MediaQuery.sizeOf(context).height - rowTop + 8;
  }

  /// Whether the system shows its own confirmation of a copy, as Android
  /// does from 13 on; a second one from the app would only repeat it.
  static Future<bool> _systemConfirmsCopies() async {
    if (!Platform.isAndroid) return false;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt >= 33;
    } catch (_) {
      return false;
    }
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

/// The sliding panel's background: rounded top corners over the brand
/// backdrop, which glows behind the artwork and keeps its tint all the way
/// to the bottom edge, [bottomInset] under the content.
///
/// A transparent [Material] sits above the gradient so the buttons' ripples
/// show: an [InkWell] paints on its nearest Material, which would otherwise
/// be the page under the panel, covered by the gradient.
class _PlayerPanel extends StatelessWidget {
  const _PlayerPanel({required this.bottomInset, required this.child});

  final double bottomInset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _BakedDecoration(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16.0),
          topRight: Radius.circular(16.0),
        ),
        // An ellipse wider than the panel, centred 18% down, so the glow
        // spreads across the top and reaches the bottom edge only at its
        // darkest.
        gradient: RadialGradient(
          center: _backdropCenter,
          // The transform's radii are fractions of a radius-1 circle, the
          // shortest side; the default radius is half of that.
          radius: 1.0,
          colors: isDark
              ? AppColors.darkPlayerBackdrop
              : AppColors.lightPlayerBackdrop,
          stops: const [0.0, 0.55, 1.0],
          transform: const _EllipticalGradientTransform(
            center: _backdropCenter,
            radii: Size(1.3, 0.75),
          ),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: _maxTextScale,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A [DecoratedBox] that shades its [decoration] once per size into an image
/// and draws that image on every frame after.
///
/// The player's backdrop gradient took a slow phone's GPU about 7 ms a frame
/// (moto g7 plus), whatever its stops or shape, and every frame of a sheet
/// sliding over the player, a song change or the panel opening redraws it:
/// a sheet lost a quarter of its frames. The image holds the same pixels
/// (one screen's worth, about 8 MB at 1080p) and costs next to nothing to
/// draw.
class _BakedDecoration extends SingleChildRenderObjectWidget {
  const _BakedDecoration({required this.decoration, super.child});

  final Decoration decoration;

  @override
  _RenderBakedDecoration createRenderObject(BuildContext context) =>
      _RenderBakedDecoration(
        decoration: decoration,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      );

  @override
  void updateRenderObject(
      BuildContext context, _RenderBakedDecoration renderObject) {
    renderObject
      ..decoration = decoration
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }
}

class _RenderBakedDecoration extends RenderProxyBox {
  _RenderBakedDecoration({
    required Decoration decoration,
    required double devicePixelRatio,
  })  : _decoration = decoration,
        _devicePixelRatio = devicePixelRatio;

  Decoration _decoration;
  set decoration(Decoration value) {
    if (value == _decoration) return;
    _decoration = value;
    _dropImage();
    markNeedsPaint();
  }

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    _dropImage();
    markNeedsPaint();
  }

  ui.Image? _image;

  /// The size [_image] was shaded for.
  Size? _imageSize;

  void _dropImage() {
    _image?.dispose();
    _image = null;
  }

  ui.Image _imageFor(Size size) {
    final cached = _image;
    if (cached != null && _imageSize == size) return cached;
    _dropImage();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(_devicePixelRatio);
    final painter = _decoration.createBoxPainter();
    painter.paint(canvas, Offset.zero, ImageConfiguration(size: size));
    painter.dispose();
    final picture = recorder.endRecording();
    // Rendered on the GPU, never read back.
    final image = picture.toImageSync(
      (size.width * _devicePixelRatio).ceil(),
      (size.height * _devicePixelRatio).ceil(),
    );
    picture.dispose();
    _imageSize = size;
    return _image = image;
  }

  // Taps on the bare backdrop land on the panel, as on a DecoratedBox,
  // instead of falling through to what is under it.
  @override
  bool hitTestSelf(Offset position) => _decoration.hitTest(size, position);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!size.isEmpty) {
      final image = _imageFor(size);
      context.canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        offset &
            Size(image.width / _devicePixelRatio,
                image.height / _devicePixelRatio),
        Paint()..filterQuality = FilterQuality.none,
      );
    }
    super.paint(context, offset);
  }

  @override
  void dispose() {
    _dropImage();
    super.dispose();
  }
}

/// Where the player backdrop's glow is brightest: centred, 18% down.
const Alignment _backdropCenter = Alignment(0.0, -0.64);

/// Stretches a [RadialGradient] of radius 1 into an ellipse whose radii are
/// fractions of the painted box's width and height, as CSS's
/// `radial-gradient(130% 75% at 50% 18%)` does. A plain [RadialGradient] is a
/// circle sized by the box's shortest side.
class _EllipticalGradientTransform extends GradientTransform {
  const _EllipticalGradientTransform({
    required this.center,
    required this.radii,
  });

  /// The gradient's centre, which the stretch keeps in place.
  final Alignment center;

  /// The ellipse's horizontal and vertical radii, as fractions of the box's
  /// width and height.
  final Size radii;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final side = bounds.shortestSide;
    if (side <= 0) return Matrix4.identity();
    final origin = center.withinRect(bounds);
    return Matrix4.identity()
      ..translateByDouble(origin.dx, origin.dy, 0, 1)
      ..scaleByDouble(radii.width * bounds.width / side,
          radii.height * bounds.height / side, 1, 1)
      ..translateByDouble(-origin.dx, -origin.dy, 0, 1);
  }
}

/// The like / dislike buttons for the playing song: two outlined circles. A
/// like floods its circle with the brand pink, a dislike with a quiet tint of
/// the text color.
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

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RatingButton(
          icon: Icons.thumb_up_outlined,
          activeIcon: Icons.thumb_up,
          label: 'Îmi place',
          isActive: likeStatus == 1,
          activeFill: AppColors.primary,
          activeForeground: Colors.white,
          onTap: onLike,
        ),
        // Each 48pt tap target pads its circle by 2, so the circles sit 10
        // apart.
        const SizedBox(width: 6),
        _RatingButton(
          icon: Icons.thumb_down_outlined,
          activeIcon: Icons.thumb_down,
          label: 'Nu-mi place',
          isActive: likeStatus == -1,
          activeFill: onSurface.withValues(alpha: 0.2),
          activeForeground: onSurface,
          onTap: onDislike,
        ),
      ],
    );
  }
}

/// One circle of [_RatingButtons]: a thin outline around a muted icon at
/// rest. Once chosen, [activeFill] floods the circle and the icon fills in
/// with a small pop.
class _RatingButton extends StatelessWidget {
  const _RatingButton({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.activeFill,
    required this.activeForeground,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;

  /// The circle's color once chosen; at rest it is see-through. The outline
  /// fades into it.
  final Color activeFill;

  /// The icon's color once chosen.
  final Color activeForeground;
  final VoidCallback onTap;

  /// Diameter of the visible circle; the padded tap target around it is 48.
  static const double _diameter = 44;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final idleBorder = onSurface.withValues(alpha: 0.24);
    final idleForeground = onSurface.withValues(alpha: 0.8);

    return Semantics(
      button: true,
      toggled: isActive,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      // IconButton snaps between colors, so they are tweened here instead.
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: isActive ? 1.0 : 0.0),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeInOut,
        builder: (context, t, child) => IconButton(
          onPressed: onTap,
          style: IconButton.styleFrom(
            fixedSize: const Size.square(_diameter),
            minimumSize: const Size.square(_diameter),
            padding: EdgeInsets.zero,
            iconSize: 20,
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.padded,
            animationDuration: Duration.zero,
            shape: const CircleBorder(),
            backgroundColor: activeFill.withValues(alpha: activeFill.a * t),
            foregroundColor: Color.lerp(idleForeground, activeForeground, t),
            side: BorderSide(
              color: Color.lerp(idleBorder, activeFill, t)!,
              width: 1.5,
            ),
          ),
          icon: child!,
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          // The filled icon pops in with a slight overshoot; the outline
          // just fades back.
          transitionBuilder: (child, animation) =>
              child.key == const ValueKey(true)
                  ? ScaleTransition(
                      scale: animation.drive(
                        CurveTween(curve: Curves.easeOutBack),
                      ),
                      child: child,
                    )
                  : FadeTransition(opacity: animation, child: child),
          child: Icon(
            isActive ? activeIcon : icon,
            key: ValueKey(isActive),
          ),
        ),
      ),
    );
  }
}

/// The small label under a player action's icon. Scales down rather than
/// wrapping when its share of the action row is too narrow.
class _ActionLabel extends StatelessWidget {
  const _ActionLabel(this.text);

  final String text;

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
            color: Theme.of(context).textSecondary,
          ),
        ),
      ),
    );
  }
}
