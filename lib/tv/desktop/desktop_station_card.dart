import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../services/playlist_controller.dart';
import '../../types/Station.dart';
import '../../types/playlist_item.dart';
import '../../utils/station_ui.dart';
import '../../widgets/station_type_badge.dart';
import '../tv_theme.dart';
import 'desktop_browse_model.dart';
import 'desktop_station_menu.dart';

/// A station in the desktop grid: its artwork across the card's width, its
/// name, its song and how many listen, snug under it.
///
/// Under the pointer the card stays in place: its artwork dims a little and
/// shows a play button and a heart. The keyboard focus rings it, and Return
/// plays it. The playing
/// station's card is tinted and outlined, and its artwork wears a "Se
/// redă" badge ("În pauză" while paused), so it
/// never relies on color alone. A click plays the station; a right-click,
/// or a Control-click on macOS, opens its menu.
class DesktopStationCard extends StatefulWidget {
  const DesktopStationCard({
    super.key,
    required this.station,
    required this.isCurrent,
    required this.isPlaying,
    required this.isFavorite,
    required this.onPlay,
    required this.onTogglePlayback,
    required this.onToggleFavorite,
    required this.onContextMenu,
    this.artworkCacheWidth,
    this.artworkSourceWidth,
    this.menuOpen = false,
    this.hidden = false,
    this.onUnhide,
  });

  final Station station;

  /// Whether the player is on this station, playing or paused.
  final bool isCurrent;

  /// Whether the player plays: with [isCurrent], this station plays.
  final bool isPlaying;

  final bool isFavorite;

  /// Plays the station.
  final VoidCallback onPlay;

  /// Pauses or resumes the player, from the playing station's card.
  final VoidCallback onTogglePlayback;

  final VoidCallback onToggleFavorite;

  /// Opens the station's menu at a global position.
  final ValueChanged<Offset> onContextMenu;

  /// The width, in physical pixels, the artwork is decoded at.
  final int? artworkCacheWidth;

  /// The width, in pixels, to ask the image CDN for; null keeps the API's.
  final int? artworkSourceWidth;

  /// Whether the station's menu is open, which keeps the card marked.
  final bool menuOpen;

  /// Whether the station is hidden and listed only in its place: dimmed,
  /// with a button that adds it back ([onUnhide]). It plays nothing and has
  /// no menu.
  final bool hidden;

  final VoidCallback? onUnhide;

  /// Height of the card's text block at the default text size: its name,
  /// its song and its listeners, with the gaps around them.
  static double textBlockHeight(TextScaler scaler) =>
      _titleGap +
      _lineHeight(scaler, _titleSize) +
      _lineGap +
      _lineHeight(scaler, _subtitleSize) +
      _lineGap +
      _lineHeight(scaler, _metaSize);

  /// How much taller than wide a card is: its text block, and a little
  /// room for rounding. The artwork is as much narrower than the card as
  /// the padding and the outline around it are tall.
  static double extraHeight(TextScaler scaler) => textBlockHeight(scaler) + 2;

  /// The width, in logical pixels, of the artwork of a card [cardWidth]
  /// wide.
  static double artworkWidth(double cardWidth) =>
      cardWidth - 2 * (DesktopTokens.cardPadding + _outlineWidth);

  static const double _outlineWidth = 1.5;

  static double _lineHeight(TextScaler scaler, double fontSize) =>
      (scaler.scale(fontSize) * _lineHeightFactor).ceilToDouble();

  static const double _titleSize = 14;
  static const double _subtitleSize = 12.5;
  static const double _metaSize = 11.5;
  static const double _lineHeightFactor = 1.3;
  static const double _titleGap = 10;
  static const double _lineGap = 2;

  static const String hiddenLabel = 'Ascunsă';
  static const String unhideLabel = 'Reafișează';
  static const String playingLabel = 'Se redă';
  static const String pausedLabel = 'În pauză';
  static const String downLabel = 'Stație posibil indisponibilă';

  @override
  State<DesktopStationCard> createState() => _DesktopStationCardState();
}

class _DesktopStationCardState extends State<DesktopStationCard> {
  bool _hovered = false;
  bool _focused = false;

  bool get _raised => !widget.hidden && (_hovered || widget.menuOpen);

  void _onTapUp(TapUpDetails details) {
    if (widget.hidden) return;
    // A Control-click opens the menu (DesktopContextClick), not the station.
    if (!kIsWeb &&
        Platform.isMacOS &&
        HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    widget.onPlay();
  }

  /// Opens the menu under the card's artwork, for the keyboard.
  void _openMenuFromKeyboard() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    widget.onContextMenu(box.localToGlobal(box.size.center(Offset.zero)));
  }

  String get _semanticsLabel {
    final station = widget.station;
    final parts = <String>[
      station.displayTitle,
      if (widget.hidden) DesktopStationCard.hiddenLabel,
      if (widget.isCurrent)
        widget.isPlaying
            ? DesktopStationCard.playingLabel
            : DesktopStationCard.pausedLabel,
      if (!widget.hidden && station.isDown) DesktopStationCard.downLabel,
      if (!widget.hidden && !station.isDown && station.songLine.isNotEmpty)
        station.songLine,
      if (widget.isFavorite) 'favorită',
    ];
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final card = _CardFrame(
      focused: _focused,
      isCurrent: widget.isCurrent && !widget.hidden,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: _Artwork(
              station: widget.station,
              cacheWidth: widget.artworkCacheWidth,
              sourceWidth: widget.artworkSourceWidth,
              hidden: widget.hidden,
              isCurrent: widget.isCurrent,
              isPlaying: widget.isPlaying,
              isFavorite: widget.isFavorite,
              showControls: _raised || _focused,
              onTogglePlayback: widget.onTogglePlayback,
              onPlay: widget.onPlay,
              onToggleFavorite: widget.onToggleFavorite,
              onUnhide: widget.onUnhide,
            ),
          ),
          _CardText(
            station: widget.station,
            isCurrent: widget.isCurrent && !widget.hidden,
            hidden: widget.hidden,
          ),
        ],
      ),
    );

    return Semantics(
      button: !widget.hidden,
      selected: widget.isCurrent,
      label: _semanticsLabel,
      onTap: widget.hidden ? null : widget.onPlay,
      customSemanticsActions: widget.hidden
          ? {
              if (widget.onUnhide case final unhide?)
                const CustomSemanticsAction(
                  label: DesktopStationCard.unhideLabel,
                ): unhide,
            }
          : {
              CustomSemanticsAction(
                label: widget.isFavorite
                    ? 'Elimină din favorite'
                    : 'Adaugă la favorite',
              ): widget.onToggleFavorite,
            },
      child: ExcludeSemantics(
        // The re-add button stays reachable on a hidden station's card.
        excluding: !widget.hidden,
        child: FocusableActionDetector(
          enabled: !widget.hidden,
          mouseCursor: widget.hidden
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          // Return plays the focused card. Space is left to the screen,
          // which plays and pauses with it wherever no text is typed.
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): _PlayIntent(),
            SingleActivator(LogicalKeyboardKey.numpadEnter): _PlayIntent(),
            SingleActivator(LogicalKeyboardKey.f10, shift: true):
                _OpenMenuIntent(),
            SingleActivator(LogicalKeyboardKey.contextMenu): _OpenMenuIntent(),
          },
          actions: {
            _PlayIntent: CallbackAction<_PlayIntent>(
              onInvoke: (_) {
                widget.onPlay();
                return null;
              },
            ),
            _OpenMenuIntent: CallbackAction<_OpenMenuIntent>(
              onInvoke: (_) {
                _openMenuFromKeyboard();
                return null;
              },
            ),
          },
          onShowHoverHighlight: (value) {
            if (_hovered != value) setState(() => _hovered = value);
          },
          onShowFocusHighlight: (value) {
            if (_focused != value) setState(() => _focused = value);
          },
          child: DesktopContextClick(
            onContextClick: widget.hidden ? null : widget.onContextMenu,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _onTapUp,
              child: card,
            ),
          ),
        ),
      ),
    );
  }
}

/// Plays the focused card's station.
class _PlayIntent extends Intent {
  const _PlayIntent();
}

/// Asks a focused card for its menu, as Shift+F10 does on other systems.
class _OpenMenuIntent extends Intent {
  const _OpenMenuIntent();
}

/// The card's surface: clear at rest and under the pointer (the artwork
/// marks the hover), tinted and outlined for the playing station, ringed
/// for the keyboard. It never moves, so the grid stays still as the pointer
/// crosses it.
class _CardFrame extends StatelessWidget {
  const _CardFrame({
    required this.focused,
    required this.isCurrent,
    required this.child,
  });

  final bool focused;
  final bool isCurrent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Color outline;
    if (focused) {
      outline = DesktopTokens.focusRing;
    } else if (isCurrent) {
      outline = DesktopTokens.playingOutline;
    } else {
      outline = Colors.transparent;
    }
    return AnimatedContainer(
      duration: DesktopTokens.hoverDuration,
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(DesktopTokens.cardPadding),
      decoration: BoxDecoration(
        color: isCurrent ? DesktopTokens.playingFill : Colors.transparent,
        borderRadius: BorderRadius.circular(DesktopTokens.cardRadius),
        // The outline keeps its width either way, so the content never
        // shifts as the playing station or the focus moves.
        border: Border.all(
          color: outline,
          width: DesktopStationCard._outlineWidth,
        ),
      ),
      child: child,
    );
  }
}

/// The square artwork with its badges: the station's kind, the heart, the
/// "now playing" badge, and the play button under the pointer.
class _Artwork extends StatelessWidget {
  const _Artwork({
    required this.station,
    required this.cacheWidth,
    required this.sourceWidth,
    required this.hidden,
    required this.isCurrent,
    required this.isPlaying,
    required this.isFavorite,
    required this.showControls,
    required this.onTogglePlayback,
    required this.onPlay,
    required this.onToggleFavorite,
    required this.onUnhide,
  });

  final Station station;
  final int? cacheWidth;
  final int? sourceWidth;
  final bool hidden;
  final bool isCurrent;
  final bool isPlaying;
  final bool isFavorite;
  final bool showControls;
  final VoidCallback onTogglePlayback;
  final VoidCallback onPlay;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onUnhide;

  @override
  Widget build(BuildContext context) {
    final image = DecoratedBox(
      decoration: BoxDecoration(
        color: TvColors.surfaceVariant,
        borderRadius: BorderRadius.circular(DesktopTokens.artworkRadius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DesktopTokens.artworkRadius),
        child: station.displayThumbnail(
          cacheWidth: cacheWidth,
          sourceWidth: sourceWidth,
        ),
      ),
    );
    if (hidden) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Opacity(opacity: 0.35, child: image),
          Center(child: _UnhideButton(onPressed: onUnhide)),
        ],
      );
    }
    final pauses = isCurrent && isPlaying;
    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: showControls ? 1 : 0,
            duration: DesktopTokens.hoverDuration,
            curve: Curves.easeOut,
            child: const _HoverScrim(),
          ),
        ),
        if (station.stationType != StationMediaType.radio)
          Positioned(
            top: 8,
            left: 8,
            child: StationTypeBadge(type: station.stationType),
          ),
        Positioned(
          top: 6,
          right: 6,
          child: _Revealed(
            visible: isFavorite || showControls,
            child: _HeartButton(
              isFavorite: isFavorite,
              onPressed: onToggleFavorite,
            ),
          ),
        ),
        if (isCurrent)
          Positioned(
            left: 8,
            bottom: 8,
            child: _NowPlayingBadge(playing: isPlaying),
          ),
        Positioned(
          right: 8,
          bottom: 8,
          child: _Revealed(
            visible: showControls,
            child: _PlayButton(
              pauses: pauses,
              onPressed: isCurrent ? onTogglePlayback : onPlay,
            ),
          ),
        ),
      ],
    );
  }
}

/// Dims the artwork under the pointer, more toward its bottom, so the
/// play button and the heart read on light covers too.
class _HoverScrim extends StatelessWidget {
  const _HoverScrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.all(
          Radius.circular(DesktopTokens.artworkRadius),
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x1A000000), Color(0x73000000)],
        ),
      ),
    );
  }
}

/// Fades and scales a small control in and out; it takes no clicks while
/// out of sight.
class _Revealed extends StatelessWidget {
  const _Revealed({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: DesktopTokens.hoverDuration,
        curve: Curves.easeOut,
        child: AnimatedScale(
          scale: visible ? 1 : 0.85,
          duration: DesktopTokens.hoverDuration,
          curve: Curves.easeOut,
          child: child,
        ),
      ),
    );
  }
}

/// The play button on a card under the pointer; pause on the playing one.
/// It grows a little under the pointer and settles back a bit while
/// pressed, so it feels like the thing to click.
class _PlayButton extends StatefulWidget {
  const _PlayButton({required this.pauses, required this.onPressed});

  final bool pauses;
  final VoidCallback onPressed;

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  bool _hovered = false;
  bool _pressed = false;

  double get _scale {
    if (_pressed) return 1.04;
    return _hovered ? 1.12 : 1;
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.pauses ? 'Pauză' : 'Redă',
      child: AnimatedScale(
        scale: _scale,
        duration: DesktopTokens.hoverDuration,
        curve: Curves.easeOut,
        child: Material(
          color: TvColors.primary,
          shape: const CircleBorder(),
          elevation: _hovered ? 6 : 4,
          shadowColor: Colors.black,
          child: InkWell(
            customBorder: const CircleBorder(),
            canRequestFocus: false,
            onTap: widget.onPressed,
            onHover: (hovered) => setState(() => _hovered = hovered),
            onHighlightChanged: (pressed) =>
                setState(() => _pressed = pressed),
            child: SizedBox.square(
              dimension: 40,
              child: Icon(
                widget.pauses
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                size: 26,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The heart on a card: always shown on a favorite, under the pointer on
/// the others.
class _HeartButton extends StatelessWidget {
  const _HeartButton({required this.isFavorite, required this.onPressed});

  final bool isFavorite;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // A dark disc under the heart, with a rim and a soft shadow, so it
    // reads on light and busy artwork alike. Not a blurred glass: the heart
    // stays on every favorite, twice when they show in the grid too, and a
    // backdrop blur is redrawn for each of them at every frame.
    return Tooltip(
      message: isFavorite ? 'Elimină din favorite' : 'Adaugă la favorite',
      child: DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Color(0x59000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Material(
          color: const Color(0xCC141414),
          shape: const CircleBorder(
            side: BorderSide(color: Color(0x33FFFFFF)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            canRequestFocus: false,
            onTap: onPressed,
            hoverColor: Colors.white.withValues(alpha: 0.12),
            child: SizedBox.square(
              dimension: 34,
              child: AnimatedSwitcher(
                duration: DesktopTokens.hoverDuration,
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(
                  isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  key: ValueKey(isFavorite),
                  size: 18,
                  color: isFavorite ? TvColors.primary : Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Se redă" on the playing station's artwork; "În pauză" while paused.
class _NowPlayingBadge extends StatelessWidget {
  const _NowPlayingBadge({required this.playing});

  final bool playing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: playing ? TvColors.primary : Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        playing
            ? DesktopStationCard.playingLabel
            : DesktopStationCard.pausedLabel,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.1,
        ),
      ),
    );
  }
}

/// The button on a hidden station's artwork that adds it back.
class _UnhideButton extends StatelessWidget {
  const _UnhideButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: const Icon(Icons.visibility_outlined, size: 18),
      label: const Text(DesktopStationCard.unhideLabel),
      style: FilledButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.72),
        foregroundColor: Colors.white,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// The station's name, its song (or why there is none) and its listeners.
class _CardText extends StatelessWidget {
  const _CardText({
    required this.station,
    required this.isCurrent,
    required this.hidden,
  });

  final Station station;
  final bool isCurrent;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        4,
        DesktopStationCard._titleGap,
        4,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            station.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: DesktopStationCard._titleSize,
              height: DesktopStationCard._lineHeightFactor,
              fontWeight: FontWeight.w600,
              color: hidden
                  ? TvColors.textTertiary
                  : isCurrent
                      ? DesktopTokens.playingText
                      : TvColors.textPrimary,
            ),
          ),
          const SizedBox(height: DesktopStationCard._lineGap),
          if (hidden)
            const _Line(text: DesktopStationCard.hiddenLabel)
          else
            _Subtitle(station: station, isCurrent: isCurrent),
          const SizedBox(height: DesktopStationCard._lineGap),
          if (!hidden) _MetaLine(station: station),
        ],
      ),
    );
  }
}

/// One line of the card's secondary text.
class _Line extends StatelessWidget {
  const _Line({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: DesktopStationCard._subtitleSize,
        height: DesktopStationCard._lineHeightFactor,
        color: color ?? TvColors.textSecondary,
      ),
    );
  }
}

/// The card's song line, as the phone's station row words it: the song,
/// a TV channel's "Transmisiune live", a playlist's item or label; "Stație
/// posibil indisponibilă", with a warning sign, for a station that is down.
class _Subtitle extends StatelessWidget {
  const _Subtitle({required this.station, required this.isCurrent});

  final Station station;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: DesktopTokens.contentDuration,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, if (current != null) current],
      ),
      child: KeyedSubtree(
        key: ValueKey('${station.id}-${station.isDown}-${station.songLine}'),
        child: _content(),
      ),
    );
  }

  Widget _content() {
    if (station.isDown) {
      return const Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 13,
            color: DesktopTokens.warning,
          ),
          SizedBox(width: 4),
          Flexible(
            child: _Line(
              text: DesktopStationCard.downLabel,
              color: DesktopTokens.warning,
            ),
          ),
        ],
      );
    }
    if (station.isPlaylist) {
      final label = computeStationSubtitle(
            type: StationMediaType.playlist,
            songLine: '',
            isRomanian: true,
            playlistItemCount: station.playlistItems.length,
          ) ??
          '';
      if (isCurrent && GetIt.instance.isRegistered<PlaylistController>()) {
        final controller = GetIt.instance<PlaylistController>();
        return StreamBuilder<PlaylistItem?>(
          stream: controller.currentItem.stream,
          initialData: controller.currentItem.valueOrNull,
          builder: (context, snapshot) {
            final title = snapshot.data?.title ?? '';
            return _Line(text: title.isNotEmpty ? title : label);
          },
        );
      }
      return _Line(text: label);
    }
    final subtitle = computeStationSubtitle(
      type: station.stationType,
      songLine: station.songLine,
      isRomanian: true,
      tvLiveFallback: true,
    );
    return _Line(
      text: subtitle == null || subtitle.isEmpty ? 'Live' : subtitle,
    );
  }
}

/// How many listen, with a dot that is green while the station is up, and
/// its rating; empty when neither is known.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.station});

  final Station station;

  @override
  Widget build(BuildContext context) {
    final int listeners = station.totalListeners ?? 0;
    final rating = station.averageRating;
    const style = TextStyle(
      fontSize: DesktopStationCard._metaSize,
      height: DesktopStationCard._lineHeightFactor,
      color: TvColors.textTertiary,
    );
    return AnimatedSwitcher(
      duration: DesktopTokens.contentDuration,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, if (current != null) current],
      ),
      child: Row(
        key: ValueKey('${station.id}-$listeners-${station.isUp}'),
        children: [
          if (listeners > 0) ...[
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(right: 5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    station.isUp ? DesktopTokens.online : DesktopTokens.warning,
              ),
            ),
            Expanded(
              child: Text(
                listenersLabel(listeners),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ] else
            const Spacer(),
          if (rating > 0) ...[
            const SizedBox(width: 6),
            const Icon(
              Icons.star_rounded,
              size: 13,
              color: DesktopTokens.rating,
            ),
            const SizedBox(width: 2),
            Text(
              rating.toStringAsFixed(1),
              style: style.copyWith(
                color: DesktopTokens.rating,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
