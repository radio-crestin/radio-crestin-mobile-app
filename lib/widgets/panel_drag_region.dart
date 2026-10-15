import 'package:flutter/widgets.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

/// Slides the sliding panel with a drag that starts on [child], where the
/// panel itself is kept from following the finger.
///
/// The panel follows every move of a finger on it, gesture or not, so it
/// would also slide away under a long press: while a menu opens and while
/// the finger slides onto an option. Here the panel moves only for a drag
/// that wins over the taps and long presses on [child], so a long press
/// holds it still.
class PanelDragRegion extends StatelessWidget {
  const PanelDragRegion({
    super.key,
    required this.controller,
    required this.travel,
    required this.child,
  });

  final PanelController controller;

  /// How far the panel slides between closed and open.
  final double travel;

  final Widget child;

  /// The release speed, in pixels per second, from which the panel's own
  /// drag goes the way of the fling rather than to the nearer end.
  static const double minFlingVelocity = 365;

  void _drag(DragUpdateDetails details) {
    if (!controller.isAttached || travel <= 0) return;
    final position = controller.panelPosition - details.primaryDelta! / travel;
    controller.panelPosition = position.clamp(0.0, 1.0);
  }

  void _settle(DragEndDetails details) {
    if (!controller.isAttached) return;
    final velocity = details.primaryVelocity ?? 0;
    final close = velocity.abs() >= minFlingVelocity
        ? velocity > 0
        : controller.panelPosition <= 0.5;
    close ? controller.close() : controller.open();
  }

  @override
  Widget build(BuildContext context) {
    return IgnoreDraggableWidget(
      child: GestureDetector(
        // Opaque, so the drag still reaches the panel while [child] ignores
        // touches.
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: _drag,
        onVerticalDragEnd: _settle,
        child: child,
      ),
    );
  }
}
