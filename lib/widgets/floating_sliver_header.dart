import 'dart:math' as math;

import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A header at the top of a scroll view that hides as the user scrolls on
/// and comes back over the list as soon as they scroll back.
///
/// Works like Flutter's [SliverFloatingHeader], except that the header only
/// follows the user's scrolling. The list also scrolls by itself to keep
/// what is on screen in place: while a liked station joins Favorite above
/// the rows in view, or while the keyboard of the search dialog changes the
/// list's bottom inset. [SliverFloatingHeader] took those for the user
/// scrolling on and hid; this header stays where it is.
class FloatingSliverHeader extends StatefulWidget {
  const FloatingSliverHeader({super.key, required this.child});

  final Widget child;

  @override
  State<FloatingSliverHeader> createState() => _FloatingSliverHeaderState();
}

class _FloatingSliverHeaderState extends State<FloatingSliverHeader>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    return _FloatingHeader(
      vsync: this,
      child: _SnapTrigger(child: widget.child),
    );
  }
}

/// Tells the header when a scroll starts and ends, so it can snap.
class _SnapTrigger extends StatefulWidget {
  const _SnapTrigger({required this.child});

  final Widget child;

  @override
  State<_SnapTrigger> createState() => _SnapTriggerState();
}

class _SnapTriggerState extends State<_SnapTrigger> {
  ScrollPosition? _position;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _position?.isScrollingNotifier.removeListener(_scrollingChanged);
    _position = Scrollable.maybeOf(context)?.position;
    _position?.isScrollingNotifier.addListener(_scrollingChanged);
  }

  @override
  void dispose() {
    _position?.isScrollingNotifier.removeListener(_scrollingChanged);
    super.dispose();
  }

  void _scrollingChanged() {
    final position = _position;
    if (position == null) return;
    context
        .findAncestorRenderObjectOfType<_RenderFloatingHeader>()
        ?.scrollingChanged(position);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _FloatingHeader extends SingleChildRenderObjectWidget {
  const _FloatingHeader({required this.vsync, super.child});

  final TickerProvider vsync;

  @override
  _RenderFloatingHeader createRenderObject(BuildContext context) =>
      _RenderFloatingHeader(vsync: vsync);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFloatingHeader renderObject,
  ) {
    renderObject.vsync = vsync;
  }
}

class _RenderFloatingHeader extends RenderSliverSingleBoxAdapter {
  _RenderFloatingHeader({required TickerProvider vsync}) : _vsync = vsync;

  static const Duration _snapDuration = Duration(milliseconds: 300);

  TickerProvider _vsync;

  set vsync(TickerProvider value) {
    if (value == _vsync) return;
    _vsync = value;
    _snapController?.resync(value);
  }

  AnimationController? _snapController;
  Animation<double>? _snap;

  /// The list's scroll offset at the last layout.
  double? _lastScrollOffset;

  /// How much of the header is above the top of the view: none while it
  /// all shows, its extent or more once it is gone.
  double _hidden = 0;

  double get _extent {
    final child = this.child;
    if (child == null) return 0;
    return switch (constraints.axis) {
      Axis.vertical => child.size.height,
      Axis.horizontal => child.size.width,
    };
  }

  /// Once the user's scroll ends, shows a part-shown header the way they
  /// scrolled back, or hides it the way they scrolled on.
  void scrollingChanged(ScrollPosition position) {
    if (position.isScrollingNotifier.value) {
      _snapController?.stop();
      return;
    }
    final show = switch (position.userScrollDirection) {
      ScrollDirection.forward => true,
      ScrollDirection.reverse => false,
      // The list scrolled by itself: the header stays as it is.
      ScrollDirection.idle => null,
    };
    if (show == null || (show ? _hidden <= 0 : _hidden >= _extent)) return;
    final controller = _snapController ??=
        AnimationController(vsync: _vsync, duration: _snapDuration)
          ..addListener(_snapped);
    _snap = controller.drive(
      Tween<double>(begin: _hidden, end: show ? 0 : _extent)
          .chain(CurveTween(curve: Curves.easeInOut)),
    );
    controller.forward(from: 0);
  }

  void _snapped() {
    final value = _snap!.value;
    if (value == _hidden) return;
    _hidden = value;
    markNeedsLayout();
  }

  @override
  void detach() {
    _snapController?.dispose();
    _snapController = null;
    super.detach();
  }

  @override
  void performLayout() {
    child?.layout(constraints.asBoxConstraints(), parentUsesSize: true);
    final extent = _extent;
    final scrollOffset = constraints.scrollOffset;
    final last = _lastScrollOffset;
    if (last == null) {
      _hidden = scrollOffset;
    } else if (constraints.userScrollDirection == ScrollDirection.idle) {
      // The list moved by itself to keep its content in place, or the
      // header is snapping: it keeps its place.
    } else if (scrollOffset < last || _hidden < extent) {
      // Positive as the user scrolls back, which brings the header in.
      var delta = last - scrollOffset;
      if (constraints.userScrollDirection == ScrollDirection.forward) {
        _hidden = math.min(_hidden, extent);
      } else {
        delta = math.min(delta, 0);
      }
      _hidden -= delta;
    } else {
      _hidden = scrollOffset;
    }
    // Never below its place at the top of the list.
    _hidden = clampDouble(_hidden, 0, scrollOffset);

    geometry = SliverGeometry(
      paintOrigin: math.min(constraints.overlap, 0.0),
      scrollExtent: extent,
      paintExtent: clampDouble(
        extent - _hidden,
        0,
        constraints.remainingPaintExtent,
      ),
      // It covers the list as it comes back rather than pushing it down.
      layoutExtent: clampDouble(
        extent - scrollOffset,
        0,
        constraints.remainingPaintExtent,
      ),
      maxPaintExtent: extent,
      hasVisualOverflow: true,
    );
    _lastScrollOffset = scrollOffset;
  }

  @override
  double childMainAxisPosition(covariant RenderObject child) =>
      geometry == null ? 0 : math.min(0, geometry!.paintExtent - _extent);

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    applyPaintTransformForBoxChild(child as RenderBox, transform);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null || !geometry!.visible) return;
    final position = childMainAxisPosition(child);
    final shift = geometry!.paintExtent - position - _extent;
    offset += switch (applyGrowthDirectionToAxisDirection(
      constraints.axisDirection,
      constraints.growthDirection,
    )) {
      AxisDirection.up => Offset(0, shift),
      AxisDirection.left => Offset(shift, 0),
      AxisDirection.right => Offset(position, 0),
      AxisDirection.down => Offset(0, position),
    };
    context.paintChild(child, offset);
  }
}
