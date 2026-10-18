import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'station_actions_menu.dart';

/// Lets the listener put the rows of a list in their own order (the
/// favorites): hold a row, then move it up or down.
///
/// Held, a row opens its menu; once the finger moves, the menu closes and
/// the row lifts and follows the finger, staying within its list. The rows
/// it passes slide out of its way, and near the top or bottom of what is
/// in view the list scrolls on. Let go, the row settles into its new place
/// and [onReorder] saves the order.
class StationReorder extends ChangeNotifier {
  StationReorder({required this.onReorder});

  /// Saves the rows' new order, as their slugs, top first.
  final ValueChanged<List<String>> onReorder;

  /// What covers the edges of the scroll view the list is in, such as a
  /// pinned header at the top or the mini player at the bottom. The lifted
  /// row stays clear of them, and the list scrolls once it reaches them.
  EdgeInsets coveredEdges = EdgeInsets.zero;

  /// How long a row takes to slide out of the way, or to settle.
  static const Duration slideDuration = Duration(milliseconds: 200);

  /// How long a row takes to lift, or to land.
  static const Duration liftDuration = Duration(milliseconds: 150);

  _RowDrag? _drag;

  /// The order just dropped, until the list the rows come from shows it.
  List<String>? _dropped;

  /// Whether the rows are taking their new places, all at once.
  bool _settling = false;

  /// Whether [slug]'s row is the one the finger moves.
  bool isMoving(String slug) => _drag?.slug == slug;

  /// Whether the rows jump to where they are now rather than slide: they
  /// take their new order, where nothing moves on screen.
  bool get isSettling => _settling;

  /// How far [slug]'s row moves to make room for the moving one.
  double shiftOf(String slug) {
    final drag = _drag;
    if (drag == null) return 0;
    final index = drag.order.indexOf(slug);
    if (index < 0 || index == drag.from) return 0;
    if (drag.from < index && index <= drag.to) return -drag.extent;
    if (drag.to <= index && index < drag.from) return drag.extent;
    return 0;
  }

  /// [items] in the order just dropped, until they come in that order:
  /// saving it reaches the list a frame or more after the drop.
  List<T> ordered<T>(List<T> items, String Function(T item) slugOf) {
    final dropped = _dropped;
    if (dropped == null) return items;
    final bySlug = {for (final item in items) slugOf(item): item};
    final result = [
      for (final slug in dropped)
        if (bySlug.remove(slug) case final item?) item,
      ...bySlug.values,
    ];
    if (listEquals(items, result)) _dropped = null;
    return result;
  }

  /// Moves [slug]'s row [by] places in [order] at once, as a screen reader
  /// asks for it.
  void move(List<String> order, String slug, int by) {
    final from = order.indexOf(slug);
    final to = from + by;
    if (from < 0 || to < 0 || to >= order.length || _drag != null) return;
    _drop([...order]..removeAt(from)..insert(to, slug));
  }

  /// Lifts the row of [slug], whose slot [row] is, from where the finger
  /// held it ([position]). [order] is the list's rows, top first, and
  /// [lifted] draws the row as it follows the finger.
  void start(
    BuildContext row, {
    required String slug,
    required List<String> order,
    required Widget Function(BuildContext context, double lift) lifted,
    required Offset position,
  }) {
    final box = row.findRenderObject();
    final overlay = Overlay.maybeOf(row);
    final from = order.indexOf(slug);
    if (_drag != null ||
        overlay == null ||
        from < 0 ||
        box is! RenderBox ||
        !box.hasSize) {
      return;
    }
    final scrollable = Scrollable.maybeOf(row);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    final drag = _RowDrag(
      slug: slug,
      order: order,
      from: from,
      rect: box.localToGlobal(Offset.zero) & box.size,
      pointer: position,
      position: scrollable?.position,
      viewport: scrollable?.context.findRenderObject() as RenderBox?,
      covered: coveredEdges,
      overlayOrigin: overlayBox?.localToGlobal(Offset.zero) ?? Offset.zero,
    );
    final themes = InheritedTheme.capture(from: row, to: overlay.context);
    drag.entry = OverlayEntry(
      builder: (context) => _LiftedRow(
        reorder: this,
        drag: drag,
        child: (context, lift) => themes.wrap(lifted(context, lift)),
      ),
    );
    drag.position?.addListener(_retarget);
    _drag = drag;
    _dropped = null;
    overlay.insert(drag.entry!);
    notifyListeners();
  }

  /// The finger moved to [position].
  void update(Offset position) {
    final drag = _drag;
    if (drag == null || drag.dropping) return;
    drag.pointer = position;
    _retarget();
  }

  /// The finger let go: the row lands where it is headed.
  void end() => _drag?.drop();

  /// The touch was taken away: the row goes back where it was.
  void cancel() {
    final drag = _drag;
    if (drag == null || drag.dropping) return;
    if (drag.to != drag.from) {
      drag.to = drag.from;
      notifyListeners();
    }
    drag.drop();
  }

  /// Follows the finger, or the list scrolling under it, and makes room
  /// where the row is headed.
  void _retarget() {
    final drag = _drag;
    if (drag == null || drag.dropping) return;
    final to = drag.target;
    drag.changed();
    if (to == drag.to) return;
    drag.to = to;
    HapticFeedback.selectionClick();
    notifyListeners();
  }

  /// The row landed: the rows take their new order at once, where they
  /// already are on screen.
  void _landed() {
    final drag = _drag;
    if (drag == null) return;
    _drag = null;
    drag.position?.removeListener(_retarget);
    drag.entry?.remove();
    drag.entry?.dispose();
    drag.dispose();
    if (drag.to == drag.from) {
      _settle();
    } else {
      _drop([...drag.order]
        ..removeAt(drag.from)
        ..insert(drag.to, drag.slug));
    }
  }

  void _drop(List<String> order) {
    _dropped = order;
    onReorder(order);
    _settle();
  }

  void _settle() {
    _settling = true;
    notifyListeners();
    _settling = false;
  }

  @override
  void dispose() {
    final drag = _drag;
    _drag = null;
    if (drag != null) {
      drag.position?.removeListener(_retarget);
      drag.entry?.remove();
      drag.entry?.dispose();
      drag.dispose();
    }
    super.dispose();
  }
}

/// One move of a row: where it started, where the finger is and where in
/// the list the row is headed. Positions are global.
class _RowDrag extends ChangeNotifier {
  _RowDrag({
    required this.slug,
    required this.order,
    required this.from,
    required this.rect,
    required this.pointer,
    required this.position,
    required this.viewport,
    required this.covered,
    required this.overlayOrigin,
  })  : to = from,
        _startPointer = pointer,
        _startPixels = position?.pixels ?? 0;

  final String slug;
  final List<String> order;
  final int from;

  /// Where the row is headed, as an index in [order].
  int to;

  /// The row's slot when it was held.
  final Rect rect;

  Offset pointer;
  final Offset _startPointer;

  final ScrollPosition? position;
  final double _startPixels;

  /// The scroll view, whose [covered] edges the row stays clear of.
  final RenderBox? viewport;
  final EdgeInsets covered;

  /// Where the overlay the row is drawn in starts on screen.
  final Offset overlayOrigin;

  OverlayEntry? entry;

  /// Whether the finger let go and the row is landing.
  bool dropping = false;

  double get extent => rect.height;

  /// The top of the first row's slot, now.
  double get _firstTop =>
      rect.top - from * extent - ((position?.pixels ?? 0) - _startPixels);

  double get _lastTop => _firstTop + (order.length - 1) * extent;

  /// The top of the slot at [index], now.
  double slotTop(int index) => _firstTop + index * extent;

  /// What is in view of the list, without its covered edges.
  Rect? get visible {
    final box = viewport;
    if (box == null || !box.attached || !box.hasSize) return null;
    final rect = MatrixUtils.transformRect(
        box.getTransformTo(null), Offset.zero & box.size);
    return Rect.fromLTRB(rect.left, rect.top + covered.top, rect.right,
        rect.bottom - covered.bottom);
  }

  /// Where the finger would put the row's top, wherever that is.
  double get _fingerTop => rect.top + pointer.dy - _startPointer.dy;

  /// The row's top under the finger: within its list, and in view.
  double get top {
    var low = _firstTop;
    var high = _lastTop;
    final visible = this.visible;
    if (visible != null) {
      final inViewLow = math.max(low, visible.top);
      final inViewHigh = math.min(high, visible.bottom - extent);
      if (inViewLow <= inViewHigh) {
        low = inViewLow;
        high = inViewHigh;
      }
    }
    return _fingerTop.clamp(low, high);
  }

  /// The slot the row's top is nearest to.
  int get target =>
      ((top - _firstTop) / extent).round().clamp(0, order.length - 1);

  /// Fastest the list scrolls under a row held at its edge.
  static const double _maxScrollSpeed = 900;

  /// Scrolls the list by what [elapsed] at the speed the finger asks for:
  /// faster the further past the edge of the view it pulls the row, and
  /// only while rows of the list are out of view there.
  void scrollFor(Duration elapsed) {
    final position = this.position;
    final visible = this.visible;
    if (position == null || visible == null || dropping) return;
    final zone = extent / 2;
    final fingerTop = _fingerTop;
    var speed = 0.0;
    if (fingerTop < visible.top + zone && _firstTop < visible.top) {
      speed = -((visible.top + zone - fingerTop) / (2 * zone)).clamp(0.0, 1.0);
    } else if (fingerTop + extent > visible.bottom - zone &&
        _lastTop + extent > visible.bottom) {
      speed =
          ((fingerTop + extent - visible.bottom + zone) / (2 * zone))
              .clamp(0.0, 1.0);
    }
    if (speed == 0) return;
    var by = speed * _maxScrollSpeed * elapsed.inMicroseconds / 1e6;
    // No further than shows the first, or the last, row.
    by = by < 0
        ? math.max(by, _firstTop - visible.top)
        : math.min(by, _lastTop + extent - visible.bottom);
    final pixels = (position.pixels + by)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (pixels != position.pixels) position.jumpTo(pixels);
  }

  void drop() {
    if (dropping) return;
    dropping = true;
    notifyListeners();
  }

  void changed() => notifyListeners();
}

/// The row as it follows the finger, above the list: lifted, it grows a
/// little and casts a shadow; landing, it slides into its slot and sinks.
class _LiftedRow extends StatefulWidget {
  const _LiftedRow({
    required this.reorder,
    required this.drag,
    required this.child,
  });

  final StationReorder reorder;
  final _RowDrag drag;
  final Widget Function(BuildContext context, double lift) child;

  @override
  State<_LiftedRow> createState() => _LiftedRowState();
}

class _LiftedRowState extends State<_LiftedRow> with TickerProviderStateMixin {
  /// The row's size when held, sunk under its open menu, and lifted.
  static const double _heldScale = 0.97;
  static const double _liftedScale = 1.03;

  late final AnimationController _lift = AnimationController(
    vsync: this,
    duration: StationReorder.liftDuration,
  )..forward();

  late final AnimationController _land = AnimationController(
    vsync: this,
    duration: StationReorder.slideDuration,
  )..addStatusListener((status) {
      if (status.isCompleted) widget.reorder._landed();
    });

  late final Ticker _scroll;
  Duration _lastTick = Duration.zero;

  /// Where the row's top was when the finger let go.
  double? _landFrom;

  @override
  void initState() {
    super.initState();
    _scroll = createTicker(_onScrollTick)..start();
    widget.drag.addListener(_onDrag);
  }

  void _onScrollTick(Duration elapsed) {
    widget.drag.scrollFor(elapsed - _lastTick);
    _lastTick = elapsed;
  }

  void _onDrag() {
    if (widget.drag.dropping && _landFrom == null) {
      _landFrom = widget.drag.top;
      _scroll.stop();
      _lift.reverse();
      _land.forward();
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.drag.removeListener(_onDrag);
    _scroll.dispose();
    _lift.dispose();
    _land.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final drag = widget.drag;
    return AnimatedBuilder(
      animation: Listenable.merge([_lift, _land]),
      builder: (context, _) {
        final landFrom = _landFrom;
        final top = landFrom == null
            ? drag.top
            : lerpDouble(landFrom, drag.slotTop(drag.to),
                Curves.easeOut.transform(_land.value))!;
        final lift = Curves.easeOut.transform(_lift.value);
        // Landing sinks back to the row's own size, not the held one.
        final scale = landFrom == null
            ? lerpDouble(_heldScale, _liftedScale, lift)!
            : lerpDouble(1, _liftedScale, lift)!;
        return Positioned(
          left: drag.rect.left - drag.overlayOrigin.dx,
          top: top - drag.overlayOrigin.dy,
          width: drag.rect.width,
          height: drag.extent,
          child: IgnorePointer(
            child: Transform.scale(
              scale: scale,
              child: widget.child(context, lift),
            ),
          ),
        );
      },
    );
  }
}

/// A row of a list the listener arranges with [reorder]: it slides out of
/// the way of the row being moved, and is that row while it moves (drawn
/// by [StationReorder] then, above the list).
class StationReorderSlot extends StatefulWidget {
  const StationReorderSlot({
    super.key,
    required this.reorder,
    required this.slug,
    required this.order,
    required this.lifted,
    required this.builder,
  });

  final StationReorder reorder;
  final String slug;

  /// The list's rows, as slugs, top first.
  final List<String> order;

  /// The row as it follows the finger, [lift] going from 0 to 1 as it
  /// lifts.
  final Widget Function(BuildContext context, double lift) lifted;

  /// The row, which [drag] moves as the finger holding it does.
  final Widget Function(BuildContext context, StationRowDrag drag) builder;

  @override
  State<StationReorderSlot> createState() => _StationReorderSlotState();
}

class _StationReorderSlotState extends State<StationReorderSlot>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin
    implements StationRowDrag {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: StationReorder.slideDuration,
    value: 1,
  );

  /// The slide under way, in logical pixels down.
  double _from = 0;
  double _to = 0;

  bool _moving = false;

  double get _offset => lerpDouble(
      _from, _to, Curves.easeInOut.transform(_slide.value))!;

  /// Kept while it moves: the finger holding it would otherwise be let go
  /// once the list scrolled it out of view.
  @override
  bool get wantKeepAlive => _moving;

  @override
  void initState() {
    super.initState();
    widget.reorder.addListener(_sync);
    // Built while a row moves: straight into the place it makes room in.
    _to = _from = widget.reorder.shiftOf(widget.slug);
    _moving = widget.reorder.isMoving(widget.slug);
  }

  @override
  void didUpdateWidget(StationReorderSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reorder != widget.reorder) {
      oldWidget.reorder.removeListener(_sync);
      widget.reorder.addListener(_sync);
    }
  }

  void _sync() {
    final reorder = widget.reorder;
    final moving = reorder.isMoving(widget.slug);
    final shift = reorder.shiftOf(widget.slug);
    if (moving == _moving && shift == _to) return;
    setState(() {
      if (moving != _moving) {
        _moving = moving;
        updateKeepAlive();
      }
      if (shift == _to) return;
      _from = reorder.isSettling ? shift : _offset;
      _to = shift;
      if (reorder.isSettling) {
        _slide.value = 1;
      } else {
        _slide.forward(from: 0);
      }
    });
  }

  @override
  void dispose() {
    widget.reorder.removeListener(_sync);
    _slide.dispose();
    super.dispose();
  }

  @override
  void start(Offset position) => widget.reorder.start(
        context,
        slug: widget.slug,
        order: widget.order,
        lifted: widget.lifted,
        position: position,
      );

  @override
  void update(Offset position) => widget.reorder.update(position);

  @override
  void end() => widget.reorder.end();

  @override
  void cancel() => widget.reorder.cancel();

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: _slide,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, _offset),
        child: child,
      ),
      // The moving row's slot stays, empty, until it lands in its new one.
      child: Opacity(
        opacity: _moving ? 0 : 1,
        child: widget.builder(context, this),
      ),
    );
  }
}
