import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../queries/getStations.graphql.dart';
import '../services/station_group_categories.dart';
import '../theme.dart';
import '../types/Station.dart';
import '../utils/romanian_count.dart';
import 'station_group_picture.dart';

/// The diameter of the category pictures in the sheet.
const double _pictureSize = 50;

/// Bottom sheet that narrows the station list to one category.
///
/// "Toate stațiile" sits on top and the categories fill a grid below it,
/// each with a picture on a pastel circle and its number of stations. One
/// tap applies the choice and closes the sheet; tapping the chosen category
/// again goes back to every station, as does "Resetează", which shows while
/// a category is chosen.
class StationGroupFilterSheet extends StatelessWidget {
  const StationGroupFilterSheet({
    super.key,
    required this.offer,
    required this.selectedGroupId,
    required this.onSelected,
  });

  /// What the sheet offers.
  final StationGroupCategories offer;

  /// The chosen category's group id, or null when every station shows.
  final int? selectedGroupId;

  /// Called with the chosen group, or null for every station, right before
  /// the sheet closes.
  final ValueChanged<Query$GetStations$station_groups?> onSelected;

  /// Shows the sheet for the API's [groups] and the app's [stations], with
  /// [selected] marked as chosen.
  static Future<void> show(
    BuildContext context, {
    required List<Query$GetStations$station_groups> groups,
    required List<Station> stations,
    required Query$GetStations$station_groups? selected,
    required ValueChanged<Query$GetStations$station_groups?> onSelected,
  }) {
    final offer =
        StationGroupCategories.compute(groups: groups, stations: stations);
    final selectedId = offer.offers(selected?.id) ? selected?.id : null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => StationGroupFilterSheet(
        offer: offer,
        selectedGroupId: selectedId,
        onSelected: onSelected,
      ),
    );
  }

  void _choose(
    BuildContext context,
    Query$GetStations$station_groups? group,
  ) {
    HapticFeedback.selectionClick();
    onSelected(group);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _DragHandle(),
          _Header(
            showReset: selectedGroupId != null,
            onReset: () => _choose(context, null),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                24 + media.padding.bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _AllStationsTile(
                    stationCount: offer.stationCount,
                    listenerCount: offer.listenerCount,
                    selected: selectedGroupId == null,
                    onTap: () => _choose(context, null),
                  ),
                  if (offer.categories.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const _SectionLabel('Categorii'),
                    const SizedBox(height: 10),
                    _CategoryGrid(
                      categories: offer.categories,
                      selectedGroupId: selectedGroupId,
                      onTap: (category) => _choose(
                        context,
                        category.group.id == selectedGroupId
                            ? null
                            : category.group,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: isDark ? Colors.white24 : Colors.black12,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.showReset, required this.onReset});

  final bool showReset;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 8, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Filtrează stații',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                ),
              ),
            ),
            if (showReset)
              TextButton(
                onPressed: onReset,
                style: TextButton.styleFrom(
                  foregroundColor: isDark
                      ? AppColors.filterAccent
                      : AppColors.filterAccentOnLight,
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Resetează'),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: theme.textSecondary,
        ),
      ),
    );
  }
}

/// "Toate stațiile": every station, with how many listen right now.
class _AllStationsTile extends StatelessWidget {
  const _AllStationsTile({
    required this.stationCount,
    required this.listenerCount,
    required this.selected,
    required this.onTap,
  });

  final int stationCount;
  final int listenerCount;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stations = romanianCount(stationCount, one: 'stație', many: 'stații');
    final subtitle = listenerCount > 0
        ? '$stations · ${formatThousands(listenerCount)} ascultă acum'
        : stations;
    return _SelectableCard(
      selected: selected,
      onTap: onTap,
      semanticLabel: 'Toate stațiile, $subtitle',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const StationGroupPicture(slug: null, size: _pictureSize),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Toate stațiile',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: theme.textSecondary),
                  ),
                ],
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 12),
              const _CheckBadge(),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryGrid extends StatelessWidget {
  const _CategoryGrid({
    required this.categories,
    required this.selectedGroupId,
    required this.onTap,
  });

  final List<StationGroupCategory> categories;
  final int? selectedGroupId;
  final ValueChanged<StationGroupCategory> onTap;

  static const double _spacing = 10;

  @override
  Widget build(BuildContext context) {
    final tileHeight = _CategoryTile.heightFor(context);
    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: constraints.maxWidth >= 520 ? 4 : 3,
          mainAxisSpacing: _spacing,
          crossAxisSpacing: _spacing,
          mainAxisExtent: tileHeight,
        ),
        itemCount: categories.length,
        itemBuilder: (context, index) {
          final category = categories[index];
          return _CategoryTile(
            category: category,
            selected: category.group.id == selectedGroupId,
            onTap: () => onTap(category),
          );
        },
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final StationGroupCategory category;
  final bool selected;
  final VoidCallback onTap;

  static const EdgeInsets _padding = EdgeInsets.fromLTRB(10, 10, 10, 11);

  /// Space between the picture and the name.
  static const double _gap = 8;

  static TextStyle _nameStyle(ThemeData theme) => TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: theme.colorScheme.onSurface,
      );

  static TextStyle _countStyle(ThemeData theme) =>
      TextStyle(fontSize: 12, color: theme.textSecondary);

  /// The height that fits the picture and both lines of text at the user's
  /// text size, measured with the fonts the tile draws with.
  static double heightFor(BuildContext context) {
    final theme = Theme.of(context);
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    double lineHeight(TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: 'Ag', style: base.merge(style)),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    return _SelectableCard.borderWidth * 2 +
        _padding.vertical +
        _pictureSize +
        _gap +
        lineHeight(_nameStyle(theme)) +
        lineHeight(_countStyle(theme));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = category.group.name;
    final count =
        romanianCount(category.stationCount, one: 'stație', many: 'stații');
    return Stack(
      children: [
        Positioned.fill(
          child: _SelectableCard(
            selected: selected,
            onTap: onTap,
            semanticLabel: '$name, $count',
            tapHint: selected ? 'arată toate stațiile' : null,
            child: Padding(
              padding: _padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  StationGroupPicture(
                    slug: category.group.slug,
                    size: _pictureSize,
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _nameStyle(theme),
                      ),
                      Text(
                        count,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _countStyle(theme),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (selected)
          const Positioned(top: 10, right: 10, child: _CheckBadge()),
      ],
    );
  }
}

/// A rounded, tappable card that turns pink while [selected].
class _SelectableCard extends StatelessWidget {
  const _SelectableCard({
    required this.selected,
    required this.onTap,
    required this.semanticLabel,
    required this.child,
    this.tapHint,
  });

  final bool selected;
  final VoidCallback onTap;
  final String semanticLabel;
  final Widget child;

  /// What a tap does, when it isn't plain choosing; screen readers say it
  /// after the label.
  final String? tapHint;

  static const double _radius = 18;

  /// The outline's width; the card keeps it, transparent, while not chosen,
  /// so choosing a card never moves its content.
  static const double borderWidth = 1.5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final idle = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.06 : 0.045,
    );
    final chosen = AppColors.primary.withValues(alpha: isDark ? 0.14 : 0.08);
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      onTap: onTap,
      onTapHint: tapHint,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          color: selected ? chosen : idle,
          borderRadius: BorderRadius.circular(_radius),
          border: Border.all(
            color: selected ? AppColors.primary : Colors.transparent,
            width: borderWidth,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(_radius),
            onTap: onTap,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The pink check mark on the chosen card.
class _CheckBadge extends StatelessWidget {
  const _CheckBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: const BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.check_rounded, size: 15, color: Colors.white),
    );
  }
}
