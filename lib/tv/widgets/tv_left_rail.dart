import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../tv_theme.dart';
import 'desktop_focusable.dart';

/// Vertical navigation rail for the TV home shell.
///
/// Four large, D-pad focusable items with icon + label. The selected item
/// is filled with the brand color; focused items get a strong border + scale.
class TvLeftRail extends StatelessWidget {
  final List<TvLeftRailItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const TvLeftRail({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(
        horizontal: TvSpacing.md,
        vertical: TvSpacing.lg,
      ),
      decoration: const BoxDecoration(
        color: TvColors.surface,
        border: Border(
          right: BorderSide(color: TvColors.divider, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Compact brand wordmark at the top
          Padding(
            padding: const EdgeInsets.only(
              left: TvSpacing.sm,
              bottom: TvSpacing.xl,
            ),
            child: Row(
              children: [
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
              ],
            ),
          ),
          for (int i = 0; i < items.length; i++) ...[
            _TvLeftRailButton(
              item: items[i],
              isSelected: i == selectedIndex,
              isFirst: i == 0,
              onSelect: () => onSelect(i),
            ),
            const SizedBox(height: TvSpacing.xs),
          ],
        ],
      ),
    );
  }
}

class TvLeftRailItem {
  final IconData icon;
  final String label;
  const TvLeftRailItem({required this.icon, required this.label});
}

class _TvLeftRailButton extends StatelessWidget {
  final TvLeftRailItem item;
  final bool isSelected;
  final bool isFirst;
  final VoidCallback onSelect;

  const _TvLeftRailButton({
    required this.item,
    required this.isSelected,
    required this.isFirst,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return DesktopFocusable(
      // First item autofocuses so the rail is the entry point on cold launch.
      autofocus: isFirst,
      onSelect: onSelect,
      region: 'rail',
      isEntryPoint: isFirst,
      builder: FocusEffects.scaleWithBorder(
        scale: 1.04,
        borderColor: TvColors.primary,
        borderWidth: 3,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: TvSpacing.md,
          vertical: TvSpacing.md,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? TvColors.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              item.icon,
              color: isSelected ? TvColors.primary : TvColors.textSecondary,
              size: 24,
            ),
            const SizedBox(width: TvSpacing.md),
            Flexible(
              child: Text(
                item.label,
                style: TextStyle(
                  color: isSelected
                      ? TvColors.primary
                      : TvColors.textPrimary,
                  fontSize: 16,
                  fontWeight:
                      isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
