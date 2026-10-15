import 'package:flutter/material.dart';

import '../queries/getStations.graphql.dart';
import '../theme.dart';
import 'station_group_picture.dart';

/// The chosen category above the station list: its picture and name, and an
/// "✕" that shows every station again.
///
/// It stands where the filter button is while a category is chosen, so the
/// filter stays visible after the sheet closes. A tap on the name opens the
/// filter sheet to pick another category.
class StationGroupChip extends StatelessWidget {
  const StationGroupChip({
    super.key,
    required this.group,
    required this.onPressed,
    required this.onCleared,
  });

  final Query$GetStations$station_groups group;

  /// Called for a tap on the picture or the name.
  final VoidCallback onPressed;

  /// Called for a tap on the "✕".
  final VoidCallback onCleared;

  /// Keeps a long category name from pushing the sort label off the row.
  static const double _maxWidth = 180;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent =
        isDark ? AppColors.filterAccent : AppColors.filterAccentOnLight;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      child: InputChip(
        avatar: StationGroupPicture(slug: group.slug, size: 24),
        avatarBoxConstraints: const BoxConstraints.tightFor(
          width: 24,
          height: 24,
        ),
        label: Text(
          group.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // The chip builds on `chipTheme.labelStyle` when the theme has one,
        // and only the light theme does: a bare style without the
        // typography's even leading, which sets the text 1 pt lower than in
        // the dark theme. `labelLarge` is complete (`inherit: false`), so the
        // chip uses it as is, the same in both themes.
        labelStyle: theme.textTheme.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: accent,
        ),
        tooltip: 'Schimbă categoria',
        onPressed: onPressed,
        onDeleted: onCleared,
        deleteIcon: const Icon(Icons.close_rounded, size: 18),
        deleteIconColor: accent,
        deleteButtonTooltipMessage: 'Arată toate stațiile',
        backgroundColor:
            AppColors.primary.withValues(alpha: isDark ? 0.14 : 0.08),
        side: BorderSide(
          color: AppColors.primary.withValues(alpha: isDark ? 0.5 : 0.35),
        ),
        shape: const StadiumBorder(),
        // Set here rather than taken from the theme: only the light theme
        // has a `chipTheme`, so the theme's values would differ between
        // themes and squeeze the chip while the app animates from one to
        // the other.
        padding: const EdgeInsets.symmetric(horizontal: 4),
        labelPadding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );
  }
}

/// The end of the sort row: the filter button, or a [StationGroupChip] in
/// its place while a category is chosen.
///
/// Cross-fades the two at the row's right edge. [AnimatedSwitcher]'s default
/// layout centres them in a stack as wide as the chip, so the filter button
/// faded in over the middle of the chip and jumped right once it had gone.
class StationFilterSlot extends StatelessWidget {
  const StationFilterSlot({super.key, required this.child});

  /// The filter button or the chip, keyed so the two cross-fade.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      layoutBuilder: _alignRight,
      child: child,
    );
  }

  static Widget _alignRight(Widget? current, List<Widget> previous) {
    return Stack(
      alignment: Alignment.centerRight,
      children: [...previous, if (current != null) current],
    );
  }
}
