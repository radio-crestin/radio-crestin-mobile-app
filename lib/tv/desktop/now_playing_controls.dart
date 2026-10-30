import 'package:flutter/material.dart';

import '../tv_theme.dart';

/// Solid colors of the desktop now-playing panel and its menus.
abstract final class NowPlayingPalette {
  /// The panel itself.
  static const Color panel = Color(0xFF15131A);

  /// Buttons and empty slots on the panel.
  static const Color card = Color(0xFF1F1B26);

  /// A button under the pointer.
  static const Color hover = Color(0xFF2A2532);

  /// A button that is on (a favorite, a liked song).
  static const Color active = Color(0xFF3A1620);

  /// The popup menus opened from the panel.
  static const Color menu = Color(0xFF231F2A);

  /// The faint rim of the panel and its menus.
  static const Color edge = Color(0x14FFFFFF);
}

/// A button of the desktop panels (now playing, Settings): an icon in a
/// pill with its [label] beside it, or with [labeled] false, an icon in a
/// circle.
///
/// It lights up under the pointer, tints while it has the keyboard focus,
/// and its [tooltip] names it (and its shortcut), which matters most when
/// the label is hidden. While [active] it takes the brand pink, as a
/// favorite heart does. A [quiet] button has no fill until the pointer is
/// on it, for secondary actions beside the main ones.
class DesktopActionButton extends StatelessWidget {
  const DesktopActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.labeled = true,
    this.active = false,
    this.quiet = false,
    this.accent,
    this.size = 40,
    this.focusNode,
  });

  /// The icon; an [AnimatedSwitcher] here animates a change of it.
  final Widget icon;

  /// The text beside the icon; any widget, so a countdown can tick in it.
  final Widget label;

  final String tooltip;
  final VoidCallback? onPressed;

  /// Whether the [label] shows; otherwise the button is a circle.
  final bool labeled;

  /// Whether the button is on.
  final bool active;

  /// Whether the button is filled only under the pointer (or while
  /// [active]).
  final bool quiet;

  /// The icon and label color while not [active]; primary text when null.
  final Color? accent;

  /// Height of the pill, and side of the circle.
  final double size;

  /// The button's keyboard focus, for a menu to return it there.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final foreground =
        active ? TvColors.primary : accent ?? TvColors.textPrimary;
    final OutlinedBorder shape =
        labeled ? const StadiumBorder() : const CircleBorder();
    final content = IconTheme.merge(
      data: IconThemeData(color: foreground, size: 19),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: foreground,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        child: labeled
            ? Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 16, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [icon, const SizedBox(width: 8), label],
                ),
              )
            : Center(child: icon),
      ),
    );
    return Tooltip(
      message: tooltip,
      waitDuration: DesktopTokens.tooltipWait,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(
          end: active
              ? NowPlayingPalette.active
              : quiet
                  ? NowPlayingPalette.card.withValues(alpha: 0)
                  : NowPlayingPalette.card,
        ),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeInOut,
        builder: (context, color, child) => Material(
          color: color,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
        child: InkWell(
          onTap: onPressed,
          focusNode: focusNode,
          customBorder: shape,
          hoverColor: Colors.white.withValues(alpha: 0.07),
          focusColor: TvColors.primary.withValues(alpha: 0.28),
          highlightColor: Colors.white.withValues(alpha: 0.05),
          splashFactory: NoSplash.splashFactory,
          child: SizedBox(
            height: size,
            width: labeled ? null : size,
            child: content,
          ),
        ),
      ),
    );
  }
}

/// The look of the popup menus opened from the desktop panels: a dark
/// rounded card with a faint rim, its rows lighting up under the pointer.
abstract final class DesktopMenuTheme {
  /// The menu card.
  static const MenuStyle menuStyle = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(NowPlayingPalette.menu),
    surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
    elevation: WidgetStatePropertyAll(12),
    shadowColor: WidgetStatePropertyAll(Color(0xCC000000)),
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: NowPlayingPalette.edge),
      ),
    ),
  );

  /// A row of the menu.
  static ButtonStyle itemStyle({Color? foreground}) => ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(
          foreground ?? TvColors.textPrimary,
        ),
        iconColor: WidgetStatePropertyAll(foreground ?? TvColors.textSecondary),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? Colors.white.withValues(alpha: 0.12)
              : states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.focused)
                  ? Colors.white.withValues(alpha: 0.08)
                  : null,
        ),
        minimumSize: const WidgetStatePropertyAll(Size(220, 40)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
      );
}

/// A line of text at the top of a desktop menu, which isn't an action:
/// what the menu does, or the state it controls.
class DesktopMenuHeader extends StatelessWidget {
  const DesktopMenuHeader({super.key, required this.title, this.subtitle});

  final String title;

  /// A second, quieter line under [title].
  final Widget? subtitle;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: TvColors.textTertiary,
                letterSpacing: 0.2,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              DefaultTextStyle.merge(
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: TvColors.textPrimary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
                child: subtitle,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A hairline between groups of a desktop menu.
class DesktopMenuDivider extends StatelessWidget {
  const DesktopMenuDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 9,
      thickness: 0.5,
      color: TvColors.divider,
    );
  }
}

/// The title of a section of the now-playing panel ("Melodii recente",
/// "Despre stație"), with a hairline to its end and an optional link
/// after it.
class NowPlayingSectionHeader extends StatelessWidget {
  const NowPlayingSectionHeader({
    super.key,
    required this.title,
    this.trailing,
  });

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: TvColors.textPrimary,
                letterSpacing: 0.2,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 1,
              color: TvColors.divider.withValues(alpha: 0.35),
            ),
          ),
          if (trailing case final trailing?) ...[
            const SizedBox(width: 8),
            trailing,
          ],
        ],
      ),
    );
  }
}
