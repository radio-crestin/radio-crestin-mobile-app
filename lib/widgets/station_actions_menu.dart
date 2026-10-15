import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

/// A station row that opens a menu of the station's actions on a long
/// press: add it to the favorites or remove it, share it, or hide it.
///
/// The menu is the platform's own, like the one on the song in the full
/// player: on iOS the pull-down menu, which the finger can slide onto an
/// action and release; on Android the Material menu, opening at the finger.
/// While it is open the row sinks a little, so it is clear which station
/// the menu is about, and a touch on the row only closes the menu.
///
/// Hiding asks [confirmHide] while the menu closes, then calls [onHide].
/// Screen readers reach every action as a custom action on the row.
///
/// With [drag], the row can also move to another place in its list: held,
/// it opens its menu as usual, and once the finger moves the menu closes
/// and the row follows the finger.
class StationActionsMenu extends StatefulWidget {
  const StationActionsMenu({
    super.key,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onShare,
    required this.confirmHide,
    required this.onHide,
    required this.child,
    this.drag,
    this.onMoveUp,
    this.onMoveDown,
  });

  /// Whether the station is a favorite, which names the favorite action.
  final bool isFavorite;

  final VoidCallback onToggleFavorite;
  final VoidCallback onShare;

  /// Asks the listener to confirm, where hiding the station needs it (a
  /// favorite); resolves to whether to go on.
  final Future<bool> Function() confirmHide;

  /// Hides the station, once the listener confirmed it.
  final VoidCallback onHide;

  /// The station row.
  final Widget child;

  /// Moves the row as the finger that held it moves; null where rows keep
  /// their places.
  final StationRowDrag? drag;

  /// Move the row one place up, or down, for screen readers; null where it
  /// can't move that way.
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  static const String addFavoriteLabel = 'Adaugă la favorite';
  static const String removeFavoriteLabel = 'Elimină din favorite';
  static const String shareLabel = 'Distribuie';
  static const String hideLabel = 'Ascunde stația';
  static const String moveUpLabel = 'Mută mai sus';
  static const String moveDownLabel = 'Mută mai jos';

  @override
  State<StationActionsMenu> createState() => _StationActionsMenuState();
}

class _StationActionsMenuState extends State<StationActionsMenu> {
  /// The row's size while its menu is open.
  static const double _sunkScale = 0.97;

  /// How far a finger holding the row moves before the row follows it: a
  /// little, so a finger that only wobbles keeps the menu open.
  static const double _dragSlop = 10;

  final _menuController = MenuController();

  /// Keeps the row's widgets, and a touch in progress on them, while the
  /// iOS menu takes its long-press layer away from around
  /// them as it closes and puts it back once closed. Without it they would
  /// be built anew each time.
  final _rowKey = GlobalKey();

  AnimationStatus _menuStatus = AnimationStatus.dismissed;

  /// Whether the listener confirmed hiding the station, which is now on its
  /// way out of the list.
  bool _hiding = false;

  /// Where the finger holding the row held it, while it still does.
  Offset? _heldAt;

  /// Whether the row follows the finger holding it.
  bool _dragging = false;

  bool get _menuOpen => _menuStatus.isForwardOrCompleted;

  bool get _cupertino => switch (Theme.of(context).platform) {
        TargetPlatform.iOS || TargetPlatform.macOS => true,
        _ => false,
      };

  String get _favoriteLabel => widget.isFavorite
      ? StationActionsMenu.removeFavoriteLabel
      : StationActionsMenu.addFavoriteLabel;

  /// Sinks the row from the moment the menu starts opening until it starts
  /// closing, and marks each opening with a haptic.
  void _handleMenuAnimation(AnimationStatus status) {
    if (!mounted) return;
    final wasOpen = _menuOpen;
    setState(() => _menuStatus = status);
    if (_menuOpen && !wasOpen) {
      if (_cupertino) {
        HapticFeedback.mediumImpact();
      } else {
        Feedback.forLongPress(context);
      }
    }
  }

  /// How long a finger holds the row before the menu opens. On iOS the
  /// menu's own long press is quicker and wins, except while the menu is
  /// still closing: it takes that long press away until it has finished,
  /// and this one fills in. A row that moves has no long press of the
  /// menu's, so this one takes its timing.
  Duration get _holdDuration => widget.drag != null && _cupertino
      ? const Duration(milliseconds: 400)
      : kLongPressTimeout;

  /// Opens the menu from a long press: on iOS under the row, on Android at
  /// the finger.
  void _onHoldStart(LongPressStartDetails details) {
    _heldAt = details.globalPosition;
    if (!_menuOpen && !_hiding) {
      _menuController.open(
          position: _cupertino ? null : details.localPosition);
    }
  }

  /// Once the finger holding the row moves, the menu closes and the row
  /// follows the finger.
  void _onHoldMove(LongPressMoveUpdateDetails details) {
    final drag = widget.drag;
    final heldAt = _heldAt;
    if (drag == null || heldAt == null || _hiding) return;
    if (!_dragging) {
      if ((details.globalPosition - heldAt).distance < _dragSlop) return;
      _dragging = true;
      _menuController.close();
      drag.start(heldAt);
    }
    drag.update(details.globalPosition);
  }

  void _onHoldEnd([LongPressEndDetails? _]) {
    _heldAt = null;
    if (!_dragging) return;
    _dragging = false;
    widget.drag?.end();
  }

  void _onHoldCancel() {
    _heldAt = null;
    if (!_dragging) return;
    _dragging = false;
    widget.drag?.cancel();
  }

  @override
  void dispose() {
    if (_dragging) widget.drag?.cancel();
    super.dispose();
  }

  /// Hides the station without waiting for the menu: its spring settles
  /// well after it looks closed, and the row plays out long after that.
  Future<void> _hide() async {
    if (_hiding || !await widget.confirmHide() || !mounted) return;
    _hiding = true;
    widget.onHide();
  }

  List<Widget> _cupertinoItems() => [
        CupertinoMenuItem(
          onPressed: widget.onToggleFavorite,
          trailing: Icon(widget.isFavorite
              ? CupertinoIcons.heart_slash
              : CupertinoIcons.heart),
          child: Text(_favoriteLabel),
        ),
        CupertinoMenuItem(
          onPressed: widget.onShare,
          trailing: const Icon(CupertinoIcons.share),
          child: const Text(StationActionsMenu.shareLabel),
        ),
        const CupertinoMenuDivider(),
        CupertinoMenuItem(
          onPressed: _hide,
          isDestructiveAction: true,
          trailing: const Icon(CupertinoIcons.eye_slash),
          child: const Text(StationActionsMenu.hideLabel),
        ),
      ];

  List<Widget> _materialItems(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return [
      MenuItemButton(
        onPressed: widget.onToggleFavorite,
        leadingIcon: Icon(widget.isFavorite
            ? Icons.heart_broken_outlined
            : Icons.favorite_border),
        child: Text(_favoriteLabel),
      ),
      MenuItemButton(
        onPressed: widget.onShare,
        leadingIcon: const Icon(Icons.share_outlined),
        child: const Text(StationActionsMenu.shareLabel),
      ),
      const Divider(height: 8),
      MenuItemButton(
        onPressed: _hide,
        leadingIcon: Icon(Icons.visibility_off_outlined, color: error),
        style: MenuItemButton.styleFrom(foregroundColor: error),
        child: const Text(StationActionsMenu.hideLabel),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final cupertino = _cupertino;
    // While the menu is open a touch on the row only closes it, as a touch
    // anywhere else does, rather than also playing the station: the menu
    // counts its anchor as part of itself, so would stay open.
    final row = Listener(
      key: _rowKey,
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        if (_menuOpen) _menuController.close();
      },
      child: IgnorePointer(
        ignoring: _menuOpen,
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                duration: _holdDuration,
                debugOwner: this,
              ),
              (recognizer) => recognizer
                ..onLongPressStart = _onHoldStart
                ..onLongPressMoveUpdate = _onHoldMove
                ..onLongPressEnd = _onHoldEnd
                ..onLongPressCancel = _onHoldCancel,
            ),
          },
          child: AnimatedScale(
            scale: _menuOpen ? _sunkScale : 1,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeInOut,
            child: widget.child,
          ),
        ),
      ),
    );
    // A touch outside the open menu only closes it. Once it is closing,
    // touches go through again: the menu would otherwise keep taking them
    // until it is gone, so the list wouldn't scroll for a moment (on iOS
    // over half a second, its spring settles well after it looks closed).
    final consumeOutsideTaps = _menuOpen;
    return Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: _favoriteLabel): widget.onToggleFavorite,
        const CustomSemanticsAction(label: StationActionsMenu.shareLabel):
            widget.onShare,
        const CustomSemanticsAction(label: StationActionsMenu.hideLabel):
            _hide,
        if (widget.onMoveUp case final moveUp?)
          const CustomSemanticsAction(label: StationActionsMenu.moveUpLabel):
              moveUp,
        if (widget.onMoveDown case final moveDown?)
          const CustomSemanticsAction(
              label: StationActionsMenu.moveDownLabel): moveDown,
      },
      child: cupertino
          ? CupertinoMenuAnchor(
              controller: _menuController,
              // A row that moves can't also slide onto the menu's actions:
              // the finger moving it would pick one.
              enableLongPressToOpen: widget.drag == null,
              enableSwipe: widget.drag == null,
              consumeOutsideTaps: consumeOutsideTaps,
              onAnimationStatusChanged: _handleMenuAnimation,
              menuChildren: _cupertinoItems(),
              child: row,
            )
          : MenuAnchor(
              controller: _menuController,
              animated: true,
              consumeOutsideTap: consumeOutsideTaps,
              onAnimationStatusChanged: _handleMenuAnimation,
              menuChildren: _materialItems(context),
              child: row,
            ),
    );
  }
}

/// Moves a station row to another place in its list, as the finger that
/// held it moves.
abstract interface class StationRowDrag {
  /// The finger moved away from [position], where it held the row.
  void start(Offset position);

  /// The finger moved to [position].
  void update(Offset position);

  /// The finger let go.
  void end();

  /// The touch was taken away before the finger let go.
  void cancel();
}
