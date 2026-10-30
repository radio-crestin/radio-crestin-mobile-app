import 'package:flutter/material.dart';

import '../tv_theme.dart';

/// The look of the desktop screen's menus (the sort menu, a station's
/// context menu): a raised dark panel with a hairline, like the system's.
class DesktopMenuStyle {
  DesktopMenuStyle._();

  /// The menu panel.
  static const MenuStyle panel = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(DesktopTokens.raisedSurface),
    surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
    shadowColor: WidgetStatePropertyAll(Colors.black),
    elevation: WidgetStatePropertyAll(12),
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
    minimumSize: WidgetStatePropertyAll(Size(220, 0)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: DesktopTokens.hairline),
      ),
    ),
  );

  /// An item of the menu; [destructive] ones (hiding a station) in red.
  ///
  /// Its text keeps the theme's (`labelLarge`, 14 medium): a text style
  /// set here would replace it, the system font with it.
  static ButtonStyle item({bool destructive = false}) {
    final color = destructive ? DesktopTokens.warning : TvColors.textPrimary;
    return MenuItemButton.styleFrom(
      foregroundColor: color,
      iconColor: destructive ? color : TvColors.textSecondary,
      minimumSize: const Size(0, 36),
      padding: const EdgeInsets.symmetric(horizontal: 14),
    ).copyWith(
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)
            ? TvColors.primary.withValues(alpha: 0.22)
            : null,
      ),
    );
  }

  /// The line between groups of items.
  static const Widget divider = Divider(
    height: 9,
    thickness: 1,
    indent: 10,
    endIndent: 10,
    color: DesktopTokens.hairline,
  );
}
