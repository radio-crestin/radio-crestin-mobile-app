import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'menu_back_guard.dart';

/// The playing song's title and artist as one button: a tap searches YouTube
/// for the song, and a long press opens a menu to copy it or search for it.
///
/// The menu is the platform's own, opening from the song like a dropdown: on
/// iOS the pull-down menu, which the finger can slide onto an option and
/// release; on Android the Material menu. BACK closes it, rather than
/// leaving the app.
///
/// While pressed, and while its menu is open, the text dims the way iOS
/// shows a pressed text button, rather than a highlight drawn around it.
///
/// A null [onSearch] (no song named) leaves the text inert, with no menu.
/// The widgets stay the same either way, so the text still crossfades into
/// the first song.
class SongActionsButton extends StatefulWidget {
  const SongActionsButton({
    super.key,
    required this.onSearch,
    required this.onCopy,
    this.onMenuOpened,
    required this.child,
  });

  /// Searches YouTube for the song, from a tap or from the menu.
  final VoidCallback? onSearch;

  /// Copies the song, from the menu or from a screen reader's actions.
  final VoidCallback? onCopy;

  /// Called as the long press opens the menu.
  final VoidCallback? onMenuOpened;

  /// The song title and artist.
  final Widget child;

  static const String copyLabel = 'Copiază';
  static const String searchLabel = 'Caută pe YouTube';

  @override
  State<SongActionsButton> createState() => _SongActionsButtonState();
}

class _SongActionsButtonState extends State<SongActionsButton> {
  /// The text's opacity while a finger is on it or its menu is open.
  static const double _pressedOpacity = 0.5;

  final _menuController = MenuController();

  late final _backGuard = MenuBackGuard(onBack: _menuController.close);

  /// Keeps the song's widgets, and a touch in progress on them, while the
  /// iOS menu takes its long-press layer away from around them as it closes
  /// and puts it back once closed. Without it they would be built anew each
  /// time, cancelling the touch.
  final _anchorKey = GlobalKey();

  bool _pressed = false;
  bool _menuOpen = false;

  /// Whether the touch on the song now in progress closed its menu, and so
  /// does nothing else.
  bool _touchClosedMenu = false;

  bool get _enabled => widget.onSearch != null;

  bool get _cupertino => switch (Theme.of(context).platform) {
        TargetPlatform.iOS || TargetPlatform.macOS => true,
        _ => false,
      };

  /// A touch on the song while its menu is open closes the menu, as a touch
  /// anywhere else does. The menu counts the song as part of itself, so it
  /// would stay open while the tap also searched.
  void _handlePointerDown(PointerDownEvent event) {
    _touchClosedMenu = _menuOpen;
    if (_touchClosedMenu) _menuController.close();
  }

  void _handleTap() {
    if (!_touchClosedMenu) widget.onSearch?.call();
  }

  void _setPressed(bool pressed) {
    if (pressed != _pressed) setState(() => _pressed = pressed);
  }

  /// Keeps the text dimmed from the moment the menu starts opening until it
  /// starts closing, and marks each opening with a haptic.
  ///
  /// The status, not the menu's `onOpen`, tells of an opening: a menu
  /// opened again while still closing never reports `onOpen`.
  void _handleMenuAnimation(AnimationStatus status) {
    final open = status.isForwardOrCompleted;
    if (!mounted || open == _menuOpen) return;
    setState(() => _menuOpen = open);
    _backGuard.open = open;
    if (!open) return;
    if (_cupertino) {
      HapticFeedback.mediumImpact();
    } else {
      Feedback.forLongPress(context);
    }
    widget.onMenuOpened?.call();
  }

  /// Opens the menu from a long press. On iOS the menu's own long press
  /// comes first and wins, except while the menu is still closing: it takes
  /// that long press away until it has finished, and this one fills in.
  void _openMenu() {
    if (!_menuOpen) _menuController.open();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _backGuard.route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _backGuard.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(SongActionsButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_enabled) return;
    // The song can go away mid-press, and with it the tap's end, or while
    // its menu is open, which then has nothing left to act on.
    _pressed = false;
    if (_menuController.isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _menuController.close();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    final cupertino = _cupertino;
    final button = Listener(
      key: _anchorKey,
      onPointerDown: _handlePointerDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: enabled ? _handleTap : null,
        onLongPress: enabled ? _openMenu : null,
        child: AnimatedOpacity(
          opacity: _pressed || _menuOpen ? _pressedOpacity : 1,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
          child: widget.child,
        ),
      ),
    );
    final onCopy = widget.onCopy;
    return MergeSemantics(
      child: Semantics(
        button: enabled,
        hint: enabled ? SongActionsButton.searchLabel : null,
        customSemanticsActions: enabled && onCopy != null
            ? {
                const CustomSemanticsAction(
                  label: SongActionsButton.copyLabel,
                ): onCopy,
              }
            : null,
        // Ignoring the pointer, rather than leaving the menu out, keeps the
        // widgets the same with and without a song.
        child: IgnorePointer(
          ignoring: !enabled,
          child: cupertino
              ? CupertinoMenuAnchor(
                  controller: _menuController,
                  enableLongPressToOpen: true,
                  consumeOutsideTaps: true,
                  onAnimationStatusChanged: _handleMenuAnimation,
                  menuChildren: [
                    CupertinoMenuItem(
                      onPressed: widget.onCopy,
                      trailing: const Icon(CupertinoIcons.doc_on_doc),
                      child: const Text(SongActionsButton.copyLabel),
                    ),
                    CupertinoMenuItem(
                      onPressed: widget.onSearch,
                      trailing: const Icon(CupertinoIcons.search),
                      child: const Text(SongActionsButton.searchLabel),
                    ),
                  ],
                  child: button,
                )
              : MenuAnchor(
                  controller: _menuController,
                  animated: true,
                  consumeOutsideTap: true,
                  alignmentOffset: const Offset(0, 8),
                  onAnimationStatusChanged: _handleMenuAnimation,
                  menuChildren: [
                    MenuItemButton(
                      onPressed: widget.onCopy,
                      leadingIcon: const Icon(Icons.content_copy),
                      child: const Text(SongActionsButton.copyLabel),
                    ),
                    MenuItemButton(
                      onPressed: widget.onSearch,
                      leadingIcon: const Icon(Icons.search),
                      child: const Text(SongActionsButton.searchLabel),
                    ),
                  ],
                  child: button,
                ),
        ),
      ),
    );
  }
}
