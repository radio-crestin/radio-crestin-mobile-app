import 'package:flutter/material.dart';

import '../../services/desktop_menu_service.dart';

/// Lets the empty parts of [child], a top bar, move the window, as a title
/// bar does: pressing there and dragging moves it, and a double-click
/// zooms it (or does what the system's Dock settings say).
///
/// Flutter can't move a macOS window itself, so this tells the window
/// whether the pointer rests on an empty part of the bar
/// ([DesktopMenuService.setOverWindowDragArea]); the window then starts
/// the move from the press itself. What takes clicks in [child] (the
/// search field, buttons) stays clickable: the pointer over it isn't over
/// an empty part. Wrap what only shows (a logo, a title) in
/// [IgnorePointer] for the window to move from there too.
class DesktopWindowDragArea extends StatefulWidget {
  const DesktopWindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopWindowDragArea> createState() => _DesktopWindowDragAreaState();
}

class _DesktopWindowDragAreaState extends State<DesktopWindowDragArea> {
  bool _over = false;

  void _set(bool over) {
    if (over == _over) return;
    _over = over;
    DesktopMenuService.setOverWindowDragArea(over);
  }

  @override
  void dispose() {
    if (_over) DesktopMenuService.setOverWindowDragArea(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Under the bar's content, so the pointer reaches it only where the
        // content has nothing to click.
        Positioned.fill(
          child: MouseRegion(
            onEnter: (_) => _set(true),
            onExit: (_) => _set(false),
            child: const SizedBox.expand(),
          ),
        ),
        widget.child,
      ],
    );
  }
}
