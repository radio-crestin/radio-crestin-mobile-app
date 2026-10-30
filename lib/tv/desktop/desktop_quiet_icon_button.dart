import 'package:flutter/material.dart';

import '../tv_theme.dart';

/// An icon button of the player bar with nothing behind its icon: the icon
/// itself lightens under the pointer, and takes the focus pink while the
/// keyboard is on it.
class DesktopQuietIconButton extends StatefulWidget {
  const DesktopQuietIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color = TvColors.textSecondary,
    this.iconSize = 21,
    this.size = 40,
  });

  /// The icon, without a color of its own; an [AnimatedSwitcher] here
  /// animates a change of it.
  final Widget icon;

  final String tooltip;
  final VoidCallback? onPressed;

  /// The icon's color at rest.
  final Color color;

  final double iconSize;

  /// Side of the square the button takes, all of it clickable.
  final double size;

  /// How far toward white the icon goes under the pointer.
  static const double hoverLightening = 0.7;

  @override
  State<DesktopQuietIconButton> createState() => _DesktopQuietIconButtonState();
}

class _DesktopQuietIconButtonState extends State<DesktopQuietIconButton> {
  final FocusNode _focus = FocusNode(debugLabel: 'desktop-quiet-icon-button');
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onFocusChanged() => setState(() {});

  /// Whether the keyboard, not a click, put the focus here, as the
  /// framework's own focus highlights tell.
  bool get _showsFocus =>
      _focus.hasFocus &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  Color get _iconColor {
    if (_showsFocus) return DesktopTokens.focusRing;
    if (_hovered) {
      return Color.lerp(
        widget.color,
        Colors.white,
        DesktopQuietIconButton.hoverLightening,
      )!;
    }
    return widget.color;
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      focusNode: _focus,
      tooltip: widget.tooltip,
      onPressed: widget.onPressed,
      onHover: (hovered) => setState(() => _hovered = hovered),
      iconSize: widget.iconSize,
      style: IconButton.styleFrom(
        overlayColor: Colors.transparent,
        minimumSize: Size.square(widget.size),
        fixedSize: Size.square(widget.size),
        padding: EdgeInsets.zero,
      ),
      icon: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: _iconColor),
        duration: DesktopTokens.hoverDuration,
        curve: Curves.easeInOut,
        builder: (context, color, icon) => IconTheme.merge(
          data: IconThemeData(color: color),
          child: icon!,
        ),
        child: widget.icon,
      ),
    );
  }
}
