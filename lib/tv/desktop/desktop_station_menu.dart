import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../types/Station.dart';
import 'desktop_menu_style.dart';
import 'desktop_station_actions.dart';

/// A station's context menu on the desktop screen, opened by a right-click
/// (or a Control-click on macOS) on its card, its search result or the mini
/// player, or by the mini player's "more" button.
///
/// It offers what the phone's long-press menu does: play or pause, add to
/// or remove from the favorites, share, copy the link and hide. Opened
/// from the player bar, it leaves out play and pause, the bar's own.
///
/// One menu serves the whole screen: [child] is the screen, and [open]
/// shows the menu at a point on it for a station. A click outside the menu
/// only closes it, as the system's menus do, rather than also playing the
/// station under the pointer.
class DesktopStationMenu extends StatefulWidget {
  const DesktopStationMenu({
    super.key,
    required this.actions,
    required this.currentSlug,
    required this.playing,
    required this.onTogglePlayback,
    required this.child,
    this.onOpenChanged,
  });

  final DesktopStationActions actions;

  /// The slug of the station the player is on, if any.
  final String? currentSlug;

  /// Whether the player plays.
  final bool playing;

  /// Pauses or resumes the player, for the station it is on.
  final VoidCallback onTogglePlayback;

  /// The screen the menu opens over.
  final Widget child;

  /// Called with the slug of the station whose menu opened, and with null
  /// once it closed, for its card to stay marked meanwhile.
  final ValueChanged<String?>? onOpenChanged;

  static const String playLabel = 'Redă';
  static const String pauseLabel = 'Pauză';
  static const String addFavoriteLabel = 'Adaugă la favorite';
  static const String removeFavoriteLabel = 'Elimină din favorite';
  static const String shareLabel = 'Distribuie…';
  static const String copyLinkLabel = 'Copiază linkul';
  static const String hideLabel = 'Ascunde stația';

  @override
  State<DesktopStationMenu> createState() => DesktopStationMenuState();
}

/// Opens and closes a [DesktopStationMenu].
class DesktopStationMenuState extends State<DesktopStationMenu> {
  final MenuController _controller = MenuController();
  final GlobalKey _anchorKey = GlobalKey(debugLabel: 'DesktopStationMenu');

  Station? _station;
  bool _fromFavorites = false;
  bool _fromPlayer = false;

  /// Where the menu opened, in global coordinates, for the share picker
  /// to point at.
  Rect? _origin;

  /// Whether the menu is open.
  bool get isOpen => _controller.isOpen;

  /// Opens the menu for [station] at [globalPosition]. [fromFavorites]:
  /// it was opened in the "Favorite" section, so playing from it steps
  /// through the favorites. [fromPlayer]: it was opened from the player
  /// bar, whose own button plays and pauses, so it leaves that out.
  /// [origin]: what the share picker points at, the point itself when
  /// null.
  void open(
    Station station,
    Offset globalPosition, {
    bool fromFavorites = false,
    bool fromPlayer = false,
    Rect? origin,
  }) {
    final box = _anchorKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    setState(() {
      _station = station;
      _fromFavorites = fromFavorites;
      _fromPlayer = fromPlayer;
      _origin = origin ??
          Rect.fromCenter(center: globalPosition, width: 2, height: 2);
    });
    _controller.open(position: box.globalToLocal(globalPosition));
  }

  /// Closes the menu; returns whether it was open.
  bool close() {
    if (!_controller.isOpen) return false;
    _controller.close();
    return true;
  }

  List<Widget> _items(Station station) {
    final actions = widget.actions;
    final isCurrent = station.slug == widget.currentSlug;
    final pauses = isCurrent && widget.playing;
    final favorite = actions.isFavorite(station);
    return [
      if (!_fromPlayer)
        MenuItemButton(
          style: DesktopMenuStyle.item(),
          leadingIcon: Icon(
            pauses ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 20,
          ),
          onPressed: () {
            if (isCurrent) {
              widget.onTogglePlayback();
              return;
            }
            actions.play(
              station,
              fromFavorites: _fromFavorites,
              source: 'desktop_menu',
            );
          },
          child: Text(pauses
              ? DesktopStationMenu.pauseLabel
              : DesktopStationMenu.playLabel),
        ),
      MenuItemButton(
        style: DesktopMenuStyle.item(),
        leadingIcon: Icon(
          favorite ? Icons.heart_broken_outlined : Icons.favorite_border,
          size: 20,
        ),
        onPressed: () =>
            actions.toggleFavorite(station, source: 'desktop_menu'),
        child: Text(favorite
            ? DesktopStationMenu.removeFavoriteLabel
            : DesktopStationMenu.addFavoriteLabel),
      ),
      DesktopMenuStyle.divider,
      MenuItemButton(
        style: DesktopMenuStyle.item(),
        leadingIcon: const Icon(Icons.ios_share_rounded, size: 20),
        onPressed: () => actions.share(station, origin: _origin),
        child: const Text(DesktopStationMenu.shareLabel),
      ),
      MenuItemButton(
        style: DesktopMenuStyle.item(),
        leadingIcon: const Icon(Icons.link_rounded, size: 20),
        onPressed: () => actions.copyLink(context, station),
        child: const Text(DesktopStationMenu.copyLinkLabel),
      ),
      DesktopMenuStyle.divider,
      MenuItemButton(
        style: DesktopMenuStyle.item(destructive: true),
        leadingIcon: const Icon(Icons.visibility_off_outlined, size: 20),
        onPressed: () => actions.hide(context, station),
        child: const Text(DesktopStationMenu.hideLabel),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final station = _station;
    return Stack(
      children: [
        widget.child,
        // The anchor lies over the screen without taking its clicks, so a
        // click on the screen counts as outside the menu and closes it.
        Positioned.fill(
          child: IgnorePointer(
            child: MenuAnchor(
              controller: _controller,
              style: DesktopMenuStyle.panel,
              consumeOutsideTap: true,
              onOpen: () => widget.onOpenChanged?.call(_station?.slug),
              onClose: () => widget.onOpenChanged?.call(null),
              menuChildren: station == null ? const [] : _items(station),
              child: SizedBox.expand(key: _anchorKey),
            ),
          ),
        ),
      ],
    );
  }
}

/// Reports a right-click on [child], or a Control-click on macOS (the
/// right-click of a one-button mouse), with where it happened.
///
/// It reads the pointer itself rather than through a [GestureDetector]:
/// while a [DesktopStationMenu] is open, a click outside it is taken to
/// close the menu, so a gesture detector under the pointer never hears of
/// it. Here the press closes the open menu and the release opens the new
/// one where the listener clicked, as the system's menus do, in one click.
class DesktopContextClick extends StatefulWidget {
  const DesktopContextClick({
    super.key,
    required this.onContextClick,
    required this.child,
  });

  /// Called with the click's global position, or null to ignore clicks.
  final ValueChanged<Offset>? onContextClick;

  final Widget child;

  /// Whether a press of [buttons] is a context click: the secondary button,
  /// or the primary one with Control held on macOS.
  static bool isContextClick(int buttons) =>
      buttons & kSecondaryMouseButton != 0 ||
      (buttons & kPrimaryMouseButton != 0 &&
          !kIsWeb &&
          Platform.isMacOS &&
          HardwareKeyboard.instance.isControlPressed);

  @override
  State<DesktopContextClick> createState() => _DesktopContextClickState();
}

class _DesktopContextClickState extends State<DesktopContextClick> {
  /// The pointer of a context click pressed on [DesktopContextClick.child]
  /// and not released yet.
  int? _pointer;

  void _onDown(PointerDownEvent event) {
    final contextClick = widget.onContextClick != null &&
        DesktopContextClick.isContextClick(event.buttons);
    _pointer = contextClick ? event.pointer : null;
  }

  void _onUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    widget.onContextClick?.call(event.position);
  }

  void _onCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _pointer = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: widget.child,
    );
  }
}
