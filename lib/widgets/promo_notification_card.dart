import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:radio_crestin/services/promo_notification_service.dart';

class PromoNotificationCard extends StatelessWidget {
  final PromoNotification notification;
  final VoidCallback onDismiss;

  const PromoNotificationCard({
    super.key,
    required this.notification,
    required this.onDismiss,
  });

  /// The X's touch area, as Material asks: its 28 px circle alone was hard
  /// to hit.
  static const double _closeTarget = 48;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [const Color(0xFF1A2332), const Color(0xFF162029)]
              : [const Color(0xFFEEF4FB), const Color(0xFFF6F9FD)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFF1565C0).withValues(alpha: 0.15),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title. Only it shares the top edge with the close button,
                // so only it leaves room for it.
                Padding(
                  padding: const EdgeInsets.only(right: 22),
                  child: Text(
                    notification.title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // Message
                Text(
                  notification.message,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.78),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                // Official platform badges
                const _BadgeRow(
                  children: [
                    _PlatformBadge(
                      iconAsset: 'assets/icons/carplay_logo.svg',
                      worksWithLabel: 'Apple CarPlay',
                    ),
                    _PlatformBadge(
                      iconAsset: 'assets/icons/android_auto_logo.svg',
                      worksWithLabel: 'Android Auto',
                    ),
                  ],
                ),
              ],
            ),
          ),
          // The X: a small circle 24 px in from the corner, whose touch
          // area reaches the corner all around it.
          Positioned(
            top: 0,
            right: 0,
            child: Tooltip(
              message: 'Închide',
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: onDismiss,
                  customBorder: const CircleBorder(),
                  child: SizedBox.square(
                    dimension: _closeTarget,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.black.withValues(alpha: 0.04),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.close,
                          size: 16,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lays out the badges side by side when they fit. Otherwise, on a narrow
/// screen or with a large text size, it puts them one under the other, all
/// as wide as the widest, so that their edges line up.
class _BadgeRow extends MultiChildRenderObjectWidget {
  const _BadgeRow({required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBadgeRow();
}

class _BadgeRowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderBadgeRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BadgeRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BadgeRowParentData> {
  static const _rowSpacing = 10.0;
  static const _columnSpacing = 8.0;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BadgeRowParentData) {
      child.parentData = _BadgeRowParentData();
    }
  }

  /// The width each badge takes on one line.
  List<double> _naturalWidths() => [
        for (final child in getChildrenAsList())
          child.getMaxIntrinsicWidth(double.infinity),
      ];

  double _rowWidth(List<double> widths) => widths.isEmpty
      ? 0
      : widths.fold(0.0, (sum, width) => sum + width) +
          _rowSpacing * (widths.length - 1);

  /// The size the badges take and where each one goes.
  (Size, List<Offset>) _layout(
    BoxConstraints constraints,
    ChildLayouter layoutChild,
  ) {
    final children = getChildrenAsList();
    if (children.isEmpty) return (constraints.smallest, const []);
    final offsets = <Offset>[];
    final widths = _naturalWidths();
    if (_rowWidth(widths) <= constraints.maxWidth) {
      final sizes = [
        for (final (i, child) in children.indexed)
          layoutChild(child, BoxConstraints(maxWidth: widths[i])),
      ];
      final height = sizes.map((size) => size.height).reduce(math.max);
      var x = 0.0;
      for (final size in sizes) {
        offsets.add(Offset(x, (height - size.height) / 2));
        x += size.width + _rowSpacing;
      }
      return (
        constraints.constrain(Size(x - _rowSpacing, height)),
        offsets,
      );
    }
    final width = math.min(widths.reduce(math.max), constraints.maxWidth);
    var y = 0.0;
    for (final child in children) {
      offsets.add(Offset(0, y));
      y += layoutChild(child, BoxConstraints.tightFor(width: width)).height +
          _columnSpacing;
    }
    return (constraints.constrain(Size(width, y - _columnSpacing)), offsets);
  }

  @override
  double computeMinIntrinsicWidth(double height) => getChildrenAsList()
      .map((child) => child.getMinIntrinsicWidth(double.infinity))
      .fold(0.0, math.max);

  @override
  double computeMaxIntrinsicWidth(double height) => _rowWidth(_naturalWidths());

  @override
  double computeMinIntrinsicHeight(double width) =>
      _layout(BoxConstraints(maxWidth: width), ChildLayoutHelper.dryLayoutChild)
          .$1
          .height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _layout(constraints, ChildLayoutHelper.dryLayoutChild).$1;

  @override
  void performLayout() {
    final (layoutSize, offsets) =
        _layout(constraints, ChildLayoutHelper.layoutChild);
    size = layoutSize;
    for (final (i, child) in getChildrenAsList().indexed) {
      (child.parentData! as _BadgeRowParentData).offset = offsets[i];
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _PlatformBadge extends StatelessWidget {
  final String iconAsset;
  final String worksWithLabel;

  const _PlatformBadge({
    required this.iconAsset,
    required this.worksWithLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SvgPicture.asset(
              iconAsset,
              width: 28,
              height: 28,
            ),
          ),
          const SizedBox(width: 8),
          // A badge wider than the card (huge text) wraps its label
          // instead of overflowing.
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Works with',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w400,
                    color: Color(0xFF999999),
                    height: 1.2,
                  ),
                ),
                Text(
                  worksWithLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
