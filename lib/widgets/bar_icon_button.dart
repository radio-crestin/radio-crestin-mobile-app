import 'package:flutter/material.dart';

/// A bare icon in one of Home's bars (the app bar, the sort row) that takes
/// touches across the whole height of its bar, [width] wide, not only on
/// the icon. As it is pressed, a circle shows under the finger and the icon
/// shrinks a little.
///
/// The icon is 22 px; iOS asks for touch targets of at least 44 pt, and
/// Material for 48 dp.
class BarIconButton extends StatefulWidget {
  const BarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.height,
    this.color,
    this.isActive = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// The height of the bar, all of which takes the button's touches.
  final double height;

  /// The icon's color: the text color, a little faded, by default.
  final Color? color;

  /// Whether a state the button turns on is on (e.g. a filter is set): it
  /// then shows tinted, on a circle.
  final bool isActive;

  /// How wide the button is, and so how far apart the icons in a bar are.
  static const double width = 48;

  @override
  State<BarIconButton> createState() => _BarIconButtonState();
}

class _BarIconButtonState extends State<BarIconButton>
    with SingleTickerProviderStateMixin {
  /// The circle tinted while [BarIconButton.isActive].
  static const double _activeCircle = 44;

  late final AnimationController _press = AnimationController(
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 200),
    vsync: this,
  );

  late final Animation<double> _scale = Tween<double>(begin: 1, end: 0.88)
      .animate(CurvedAnimation(parent: _press, curve: Curves.easeInOut));

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final active = widget.isActive;
    return ScaleTransition(
      scale: _scale,
      child: Semantics(
        button: true,
        // Without a shape: a circle one would take touches on the circle
        // only, leaving out the corners and the bar above and below it.
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            // `onTap` (not `onTapUp`) carries the action: it is what InkWell
            // exposes to TalkBack/VoiceOver, Switch/Voice Access and the
            // keyboard. It fires right after `onTapUp` in the same gesture.
            onTap: widget.onPressed,
            onTapDown: (_) => _press.forward(),
            onTapUp: (_) => _press.reverse(),
            onTapCancel: _press.reverse,
            customBorder: const CircleBorder(),
            child: Tooltip(
              message: widget.tooltip,
              child: SizedBox(
                width: BarIconButton.width,
                height: widget.height,
                child: Center(
                  child: Ink(
                    width: _activeCircle,
                    height: _activeCircle,
                    decoration: ShapeDecoration(
                      shape: const CircleBorder(),
                      color: active
                          ? colorScheme.primary.withValues(alpha: 0.12)
                          : Colors.transparent,
                    ),
                    child: Icon(
                      widget.icon,
                      size: 22,
                      color: active
                          ? colorScheme.primary
                          : widget.color ??
                              colorScheme.onSurface.withValues(alpha: 0.85),
                    ),
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
