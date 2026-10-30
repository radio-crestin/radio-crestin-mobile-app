import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../services/playlist_controller.dart';
import '../../types/Station.dart';
import '../../types/playlist_item.dart';
import '../../utils/station_ui.dart';
import '../../widgets/animated_play_button.dart';
import '../../widgets/station_type_badge.dart';
import '../tv_theme.dart';
import 'desktop_quiet_icon_button.dart';
import 'desktop_shortcuts.dart';
import 'desktop_station_menu.dart';
import 'desktop_volume_control.dart';

/// The bar at the bottom of the desktop screen with the station playing:
/// what plays on the left, the transport in the middle, the favorite, the
/// volume and "more" on the right (sharing is in the more menu).
///
/// The arrow at its end opens "Se redă acum"; the rest of the bar takes
/// no click, so a click that misses a button does nothing unexpected. A
/// right-click opens the station's menu. The play button is the phone's:
/// it answers at once and shows a spinner while the station loads.
class DesktopMiniPlayer extends StatelessWidget {
  const DesktopMiniPlayer({
    super.key,
    required this.station,
    required this.playing,
    required this.isFavorite,
    required this.playbackState,
    required this.playButtonKey,
    required this.onOpen,
    required this.onPlay,
    required this.onPause,
    required this.onPrevious,
    required this.onNext,
    required this.onToggleFavorite,
    required this.onMenu,
    required this.volume,
    required this.onVolumeChanged,
    required this.onToggleMute,
  });

  final Station station;

  /// Whether the player plays, for the tooltips.
  final bool playing;

  final bool isFavorite;

  /// The player's state, for the play button.
  final Stream<PlaybackState> playbackState;

  /// The play button's key, for skips to show it loading at once.
  final GlobalKey<AnimatedPlayButtonState> playButtonKey;

  /// Opens "Se redă acum".
  final VoidCallback onOpen;

  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToggleFavorite;

  /// Opens the station's menu at a global position.
  final ValueChanged<Offset> onMenu;

  /// The listener's volume, 0..1, and where its changes go.
  final Stream<double> volume;
  final ValueChanged<double> onVolumeChanged;

  /// Mutes, or unmutes back to the volume before.
  final VoidCallback onToggleMute;

  /// Room around the bar, inside the bottom of the window.
  static const EdgeInsets margin = EdgeInsets.fromLTRB(12, 4, 12, 12);

  /// Corner radius of the bar.
  static const double radius = 16;

  /// Where the bar is in a window of [size]: "Se redă acum" grows out of
  /// it.
  static Rect rectIn(Size size) => Rect.fromLTRB(
        margin.left,
        size.height - margin.bottom - DesktopTokens.miniPlayerHeight,
        size.width - margin.right,
        size.height - margin.bottom,
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: Semantics(
        container: true,
        label: 'Player',
        child: DesktopContextClick(
          onContextClick: onMenu,
          child: Container(
            height: DesktopTokens.miniPlayerHeight,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: DesktopTokens.raisedSurface,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: DesktopTokens.hairline),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 18,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: _NowPlaying(station: station),
                ),
                const SizedBox(width: 12),
                _Transport(
                  playing: playing,
                  playbackState: playbackState,
                  playButtonKey: playButtonKey,
                  onPlay: onPlay,
                  onPause: onPause,
                  onPrevious: onPrevious,
                  onNext: onNext,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    // A narrow window gets a shorter volume slider.
                    child: LayoutBuilder(
                      builder: (context, constraints) => _Extras(
                        stationSlug: station.slug,
                        playing: playing,
                        isFavorite: isFavorite,
                        onToggleFavorite: onToggleFavorite,
                        onMenu: onMenu,
                        onOpen: onOpen,
                        volume: volume,
                        onVolumeChanged: onVolumeChanged,
                        onToggleMute: onToggleMute,
                        volumeSliderWidth:
                            constraints.maxWidth < 300 ? 64 : 84,
                      ),
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

/// The artwork, the station's name and what it plays.
class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.station});

  final Station station;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox.square(
            dimension: 52,
            child: AnimatedSwitcher(
              duration: DesktopTokens.contentDuration,
              child: KeyedSubtree(
                key: ValueKey('mini-art-${station.artUri}'),
                child: station.displayThumbnail(cacheWidth: 156),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (station.stationType != StationMediaType.radio) ...[
                    StationTypeBadge(type: station.stationType, compact: true),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: DesktopTokens.contentDuration,
                      layoutBuilder: _leftAligned,
                      child: Text(
                        station.displayTitle,
                        key: ValueKey('mini-title-${station.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: TvColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              _MiniSubtitle(station: station),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _leftAligned(Widget? current, List<Widget> previous) => Stack(
      alignment: Alignment.centerLeft,
      children: [...previous, if (current != null) current],
    );

/// What the station plays, as the phone's mini player words it: the song,
/// a playlist's item, a TV channel's "Transmisiune live".
class _MiniSubtitle extends StatelessWidget {
  const _MiniSubtitle({required this.station});

  final Station station;

  Widget _text(String value) => AnimatedSwitcher(
        duration: DesktopTokens.contentDuration,
        layoutBuilder: _leftAligned,
        child: Text(
          value,
          key: ValueKey('mini-sub-${station.id}-$value'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            color:
                station.isDown ? DesktopTokens.warning : TvColors.textSecondary,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (station.isDown) return _text('Stație posibil indisponibilă');
    if (station.isPlaylist) {
      final label = computeStationSubtitle(
            type: StationMediaType.playlist,
            songLine: '',
            isRomanian: true,
          ) ??
          '';
      if (!GetIt.instance.isRegistered<PlaylistController>()) {
        return _text(label);
      }
      final controller = GetIt.instance<PlaylistController>();
      return StreamBuilder<PlaylistItem?>(
        stream: controller.currentItem.stream,
        initialData: controller.currentItem.valueOrNull,
        builder: (context, snapshot) {
          final title = snapshot.data?.title ?? '';
          return _text(title.isNotEmpty ? title : label);
        },
      );
    }
    final subtitle = computeStationSubtitle(
      type: station.stationType,
      songLine: station.songLine,
      isRomanian: true,
      tvLiveFallback: true,
    );
    return _text(subtitle == null || subtitle.isEmpty ? 'Live' : subtitle);
  }
}

/// Previous, play/pause and next.
class _Transport extends StatelessWidget {
  const _Transport({
    required this.playing,
    required this.playbackState,
    required this.playButtonKey,
    required this.onPlay,
    required this.onPause,
    required this.onPrevious,
    required this.onNext,
  });

  final bool playing;
  final Stream<PlaybackState> playbackState;
  final GlobalKey<AnimatedPlayButtonState> playButtonKey;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _BarButton(
          icon: Icons.skip_previous_rounded,
          tooltip: 'Stația anterioară (${DesktopShortcuts.previousHint})',
          onPressed: onPrevious,
          iconSize: 26,
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: playing
              ? 'Pauză (${DesktopShortcuts.playPauseHint})'
              : 'Redă (${DesktopShortcuts.playPauseHint})',
          child: AnimatedPlayButton(
            key: playButtonKey,
            playbackStateStream: playbackState,
            iconSize: 28,
            iconColor: Colors.white,
            backgroundColor: TvColors.primary,
            onPlay: onPlay,
            onPause: onPause,
          ),
        ),
        const SizedBox(width: 6),
        _BarButton(
          icon: Icons.skip_next_rounded,
          tooltip: 'Stația următoare (${DesktopShortcuts.nextHint})',
          onPressed: onNext,
          iconSize: 26,
        ),
      ],
    );
  }
}

/// The heart, the volume, "more" and the "open player" arrow.
class _Extras extends StatelessWidget {
  const _Extras({
    required this.stationSlug,
    required this.playing,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onMenu,
    required this.onOpen,
    required this.volume,
    required this.onVolumeChanged,
    required this.onToggleMute,
    required this.volumeSliderWidth,
  });

  final String stationSlug;
  final bool playing;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;
  final ValueChanged<Offset> onMenu;
  final Stream<double> volume;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final double volumeSliderWidth;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _BarButton(
          icon: isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          color: isFavorite ? TvColors.primary : null,
          tooltip: isFavorite
              ? 'Elimină din favorite (${DesktopShortcuts.favoriteHint})'
              : 'Adaugă la favorite (${DesktopShortcuts.favoriteHint})',
          onPressed: onToggleFavorite,
        ),
        const SizedBox(width: 4),
        DesktopVolumeControl(
          volume: volume,
          onChanged: onVolumeChanged,
          onToggleMute: onToggleMute,
          stationSlug: stationSlug,
          playing: playing,
          sliderWidth: volumeSliderWidth,
        ),
        const SizedBox(width: 4),
        Builder(
          builder: (context) => _BarButton(
            icon: Icons.more_horiz_rounded,
            tooltip: 'Mai multe',
            onPressed: () {
              final box = context.findRenderObject();
              if (box is! RenderBox || !box.hasSize) return;
              onMenu(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
            },
          ),
        ),
        _BarButton(
          icon: Icons.keyboard_arrow_up_rounded,
          tooltip: 'Se redă acum (${DesktopShortcuts.nowPlayingHint})',
          onPressed: onOpen,
        ),
      ],
    );
  }
}

/// An icon button of the bar, its icon lightening under the pointer.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.iconSize = 21,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return DesktopQuietIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: iconSize,
      color: color ?? TvColors.textSecondary,
      icon: AnimatedSwitcher(
        duration: DesktopTokens.hoverDuration,
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: child),
        child: Icon(icon, key: ValueKey(icon)),
      ),
    );
  }
}
