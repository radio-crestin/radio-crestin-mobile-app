import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../tv_platform.dart';

/// A wrapper around [DpadFocusable] that adds mouse click and hover support
/// for desktop platforms. On Android TV, behaves identically to DpadFocusable.
///
/// On desktop:
/// - Click triggers [onSelect]
/// - Hover shows focus border (mouse cursor changes to pointer)
/// - Scroll events pass through naturally (no gesture absorption)
/// - Keyboard Enter/Space still works for focused items
class DesktopFocusable extends StatefulWidget {
  final Widget? child;
  final bool autofocus;
  final VoidCallback? onFocus;
  final VoidCallback? onBlur;
  final VoidCallback? onSelect;
  final bool enabled;
  final FocusEffectBuilder? builder;
  final String? debugLabel;

  const DesktopFocusable({
    super.key,
    this.child,
    this.autofocus = false,
    this.onFocus,
    this.onBlur,
    this.onSelect,
    this.enabled = true,
    this.builder,
    this.debugLabel,
  });

  @override
  State<DesktopFocusable> createState() => _DesktopFocusableState();
}

class _DesktopFocusableState extends State<DesktopFocusable> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    if (!TvPlatform.isDesktop) {
      // Pure TV mode — DpadFocusable only
      return DpadFocusable(
        autofocus: widget.autofocus,
        onFocus: widget.onFocus,
        onBlur: widget.onBlur,
        onSelect: widget.onSelect,
        enabled: widget.enabled,
        builder: widget.builder,
        debugLabel: widget.debugLabel,
        child: widget.child,
      );
    }

    // Desktop: wrap with mouse support
    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (widget.enabled) setState(() => _isHovered = true);
      },
      onExit: (_) {
        setState(() => _isHovered = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.enabled ? widget.onSelect : null,
        child: DpadFocusable(
          autofocus: widget.autofocus,
          onFocus: widget.onFocus,
          onBlur: widget.onBlur,
          onSelect: widget.onSelect,
          enabled: widget.enabled,
          builder: _desktopBuilder,
          debugLabel: widget.debugLabel,
          child: widget.child,
        ),
      ),
    );
  }

  /// On desktop, combine hover state with focus state for the builder.
  Widget _desktopBuilder(BuildContext context, bool isFocused, Widget? child) {
    final effectivelyFocused = isFocused || _isHovered;
    if (widget.builder != null) {
      return widget.builder!(context, effectivelyFocused, child);
    }
    return FocusEffects.border()(context, effectivelyFocused, child!);
  }
}
