import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../tv_theme.dart';
import 'desktop_focusable.dart';

/// Horizontal navigation bar for the TV home shell.
///
/// Replaces the previous left rail. Logo + brand mark on the left,
/// four icon-and-label tabs to the right. Selected tab is filled with the
/// brand color; focused tab gets a strong border + scale.
class TvTopTabBar extends StatelessWidget {
  static const double height = 72.0;

  final List<TvTopTabItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const TvTopTabBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: const BoxDecoration(
        color: TvColors.surface,
        border: Border(
          bottom: BorderSide(color: TvColors.divider, width: 1),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: TvSpacing.marginHorizontal,
        ),
        child: Row(
          children: [
            // Brand mark
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: TvColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.radio_rounded,
                  color: Colors.white, size: 22),
            ),
            const SizedBox(width: TvSpacing.sm),
            const Flexible(
              flex: 0,
              child: Text(
                'Radio Crestin',
                style: TextStyle(
                  color: TvColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: TvSpacing.xl),
            // Tabs — scroll horizontally on narrow surfaces so the row
            // never overflows. On a 1920px TV all tabs fit naturally.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < items.length; i++) ...[
                      _TvTopTabButton(
                        item: items[i],
                        isSelected: i == selectedIndex,
                        isFirst: i == 0,
                        onSelect: () => onSelect(i),
                      ),
                      if (i < items.length - 1)
                        const SizedBox(width: TvSpacing.xs),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TvTopTabItem {
  final IconData icon;
  final String label;
  const TvTopTabItem({required this.icon, required this.label});
}

class _TvTopTabButton extends StatelessWidget {
  final TvTopTabItem item;
  final bool isSelected;
  final bool isFirst;
  final VoidCallback onSelect;

  const _TvTopTabButton({
    required this.item,
    required this.isSelected,
    required this.isFirst,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return DesktopFocusable(
      // First tab autofocuses so the bar is the entry point on cold launch.
      autofocus: isFirst,
      onSelect: onSelect,
      region: 'top-bar',
      isEntryPoint: isFirst,
      builder: FocusEffects.scaleWithBorder(
        scale: 1.06,
        borderColor: TvColors.primary,
        borderWidth: 3,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: TvSpacing.md,
          vertical: TvSpacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? TvColors.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              item.icon,
              color: isSelected ? TvColors.primary : TvColors.textSecondary,
              size: 22,
            ),
            const SizedBox(width: TvSpacing.sm),
            Text(
              item.label,
              style: TextStyle(
                color: isSelected ? TvColors.primary : TvColors.textPrimary,
                fontSize: 15,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
