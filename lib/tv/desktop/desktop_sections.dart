import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../types/Station.dart';
import '../../utils/romanian_count.dart';
import '../tv_theme.dart';
import 'desktop_browse_model.dart';
import 'desktop_station_card.dart';

/// Builds a station's card for the grid, sized by [metrics].
typedef DesktopCardBuilder = Widget Function(
  BuildContext context,
  Station station,
  DesktopGridMetrics metrics,
);

/// A section's header: its title, how many stations it has, and an
/// optional control at its end (the sort menu).
///
/// Another title (another category chosen) fades in, in place at the
/// start of the row, from the frame its stations show. The old one leaves
/// at once rather than fading out: the section moves as the category
/// changes, from under the favorites to the top, so a fading "Toate
/// stațiile" would show over the new category's stations. A new count for
/// the same title just shows.
class DesktopSectionHeader extends StatelessWidget {
  const DesktopSectionHeader({
    super.key,
    required this.title,
    required this.count,
    this.trailing,
  });

  final String title;
  final int count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: DesktopTokens.sectionHeaderHeight,
      color: TvColors.background,
      padding: const EdgeInsets.symmetric(
        horizontal: DesktopTokens.gutter,
      ),
      child: Row(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: DesktopTokens.contentDuration,
              switchInCurve: Curves.easeOut,
              // Only the new title is laid out: the old one is gone.
              layoutBuilder: (current, previous) => Align(
                alignment: AlignmentDirectional.centerStart,
                child: current,
              ),
              child: _SectionTitle(
                key: ValueKey(title),
                title: title,
                count: count,
              ),
            ),
          ),
          if (trailing case final trailing?) ...[
            const SizedBox(width: 12),
            trailing,
          ],
        ],
      ),
    );
  }
}

/// A section's title and its number of stations.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({super.key, required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Semantics(
            header: true,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                color: TvColors.textPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          romanianCount(count, one: 'stație', many: 'stații'),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: TvColors.textTertiary,
          ),
        ),
      ],
    );
  }
}

/// The station cards of a section as a grid that fills the width: as many
/// columns as keep the cards at most [DesktopTokens.cardMaxWidth] wide.
class DesktopStationGrid extends StatelessWidget {
  const DesktopStationGrid({
    super.key,
    required this.stations,
    required this.cardBuilder,
    required this.keyPrefix,
  });

  final List<Station> stations;
  final DesktopCardBuilder cardBuilder;

  /// Tells this grid's cards from another's, the same station in both.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final metrics = DesktopGridMetrics.forWidth(
          constraints.crossAxisExtent - 2 * DesktopTokens.gutter,
          maxTileWidth: DesktopTokens.cardMaxWidth,
          spacing: DesktopTokens.gridSpacing,
          extraHeight: DesktopStationCard.extraHeight(scaler),
        );
        final indexBySlug = {
          for (final (index, station) in stations.indexed)
            '$keyPrefix-${station.slug}': index,
        };
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            DesktopTokens.gutter,
            4,
            DesktopTokens.gutter,
            DesktopTokens.gutter,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: metrics.columns,
              mainAxisSpacing: DesktopTokens.gridSpacing,
              crossAxisSpacing: DesktopTokens.gridSpacing,
              mainAxisExtent: metrics.tileHeight,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => KeyedSubtree(
                key: ValueKey('$keyPrefix-${stations[index].slug}'),
                child: cardBuilder(context, stations[index], metrics),
              ),
              childCount: stations.length,
              // A card keeps its state (hover, keyboard focus) as the others
              // move around it.
              findChildIndexCallback: (key) => key is ValueKey<String>
                  ? indexBySlug[key.value]
                  : null,
            ),
          ),
        );
      },
    );
  }
}

/// The line above a category's hidden stations shown in their places,
/// with a crossed eye.
class DesktopHiddenNote extends StatelessWidget {
  const DesktopHiddenNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DesktopTokens.gutter,
        0,
        DesktopTokens.gutter,
        8,
      ),
      child: Row(
        children: [
          const Icon(
            Icons.visibility_off_outlined,
            size: 16,
            color: TvColors.textTertiary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: AnimatedSwitcher(
              duration: DesktopTokens.contentDuration,
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.centerLeft,
                children: [...previous, if (current != null) current],
              ),
              child: Text(
                text,
                key: ValueKey(text),
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: TvColors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A message in the middle of the screen, where stations would be: an
/// icon, a title, a line of help and, optionally, a button.
class DesktopMessage extends StatelessWidget {
  const DesktopMessage({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Shows a spinner instead of [icon].
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const SizedBox.square(
                  dimension: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: TvColors.primary,
                  ),
                )
              else
                Icon(icon, size: 44, color: TvColors.textTertiary),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: TvColors.textPrimary,
                ),
              ),
              if (body case final body?) ...[
                const SizedBox(height: 6),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: TvColors.textSecondary,
                  ),
                ),
              ],
              if (actionLabel case final label?) ...[
                const SizedBox(height: 18),
                FilledButton.tonal(
                  onPressed: onAction,
                  style: FilledButton.styleFrom(
                    backgroundColor: DesktopTokens.controlHoverFill,
                    foregroundColor: TvColors.textPrimary,
                  ),
                  child: Text(label),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps what the listener looks at in place while [sliver], a section
/// above it, grows or shrinks: a favorite added or removed adds or drops a
/// row of the "Favorite" section, which would otherwise push the grid in
/// view by a row, so the station just liked seems to vanish.
///
/// While the viewport starts past the section's end, a change of its
/// height scrolls by the same amount in the same frame, as browsers anchor
/// scrolling. At the top, where the section is in view, it grows in place.
class DesktopScrollAnchor extends SingleChildRenderObjectWidget {
  const DesktopScrollAnchor({super.key, required Widget sliver})
      : super(child: sliver);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderScrollAnchor();
}

class _RenderScrollAnchor extends RenderProxySliver {
  /// The section's height at the last layout; null before the first.
  double? _lastExtent;

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints, parentUsesSize: true);
    final childGeometry = child.geometry!;
    final last = _lastExtent;
    _lastExtent = childGeometry.scrollExtent;
    final scrolledPast = last != null &&
        constraints.scrollOffset > 0 &&
        constraints.scrollOffset >= last;
    if (scrolledPast && childGeometry.scrollExtent != last) {
      geometry = SliverGeometry(
        scrollOffsetCorrection: childGeometry.scrollExtent - last,
      );
      return;
    }
    geometry = childGeometry;
  }
}
