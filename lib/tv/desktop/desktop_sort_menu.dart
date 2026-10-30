import 'package:flutter/material.dart';

import '../../services/station_sort_service.dart';
import '../tv_theme.dart';
import 'desktop_menu_style.dart';

/// The sort order of the station list, as a label that opens a menu of
/// the orders under it: the phone's sort sheet as a desktop menu.
class DesktopSortMenu extends StatelessWidget {
  const DesktopSortMenu({
    super.key,
    required this.value,
    required this.onSelected,
    this.controller,
  });

  final StationSortOption value;

  final ValueChanged<StationSortOption> onSelected;

  /// Opens and closes the menu from outside, e.g. to close it on Esc.
  final MenuController? controller;

  /// Keeps a long order's name from pushing the section's title aside.
  static const double _maxLabelWidth = 230;

  static Color _iconColor(StationSortOption option, {required bool chosen}) {
    if (option == StationSortOption.recommended) {
      return DesktopTokens.recommended;
    }
    return chosen ? TvColors.primaryLight : TvColors.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: controller,
      style: DesktopMenuStyle.panel,
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final option in StationSortOption.values)
          MenuItemButton(
            style: DesktopMenuStyle.item(),
            leadingIcon: Icon(
              StationSortLabels.icons[option],
              size: 18,
              color: _iconColor(option, chosen: option == value),
            ),
            trailingIcon: option == value
                ? const Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: TvColors.primaryLight,
                  )
                : const SizedBox(width: 18),
            onPressed: () {
              if (option != value) onSelected(option);
            },
            child: Text(StationSortLabels.labels[option] ?? ''),
          ),
      ],
      builder: (context, controller, _) => _SortButton(
        value: value,
        open: controller.isOpen,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// The sort order's icon and name with a chevron, lit under the pointer
/// and while its menu is open.
class _SortButton extends StatelessWidget {
  const _SortButton({
    required this.value,
    required this.open,
    required this.onPressed,
  });

  final StationSortOption value;
  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = StationSortLabels.labels[value] ?? '';
    return Tooltip(
      message: 'Ordinea stațiilor',
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: TvColors.textPrimary,
          backgroundColor:
              open ? DesktopTokens.controlHoverFill : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: const StadiumBorder(),
        ).copyWith(
          overlayColor: const WidgetStatePropertyAll(
            DesktopTokens.controlHoverFill,
          ),
        ),
        child: Semantics(
          label: 'Ordinea stațiilor: $label',
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                StationSortLabels.icons[value],
                size: 17,
                color: DesktopSortMenu._iconColor(value, chosen: true),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: DesktopSortMenu._maxLabelWidth,
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: DesktopTokens.hoverDuration,
                child: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: TvColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
