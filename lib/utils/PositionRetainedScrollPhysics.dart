import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

class PositionRetainedScrollPhysics extends ScrollPhysics {
  final bool shouldRetain;

  /// Keeps its sliver in place across a change it was told to hold for.
  final SliverAnchor? anchor;

  /// Keeps the rows in view in place while rows grow or shrink.
  final RowScrollAnchor? rows;

  const PositionRetainedScrollPhysics({
    super.parent,
    this.shouldRetain = true,
    this.anchor,
    this.rows,
  });

  @override
  PositionRetainedScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return PositionRetainedScrollPhysics(
      parent: buildParent(ancestor),
      shouldRetain: shouldRetain,
      anchor: anchor,
      rows: rows,
    );
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final position = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );

    final anchored = anchor?.takePosition(oldPosition.pixels) ??
        rows?.takePosition(oldPosition, newPosition);
    if (anchored != null) {
      return anchored.clamp(
        newPosition.minScrollExtent,
        newPosition.maxScrollExtent,
      );
    }

    final diff = newPosition.maxScrollExtent - oldPosition.maxScrollExtent;

    if (oldPosition.pixels > oldPosition.minScrollExtent &&
        shouldRetain) {
      return position + diff;
    } else {
      return position;
    }
  }
}

/// Keeps one sliver where it is on screen while the slivers above it change.
///
/// Give the sliver [key], pass the anchor to [PositionRetainedScrollPhysics]
/// and call [hold] right before a change that adds or removes content above
/// the sliver, e.g. the Favorite section coming back when the chosen
/// category is cleared. The layout that shows the change then scrolls by as
/// much as changed above the sliver, so it doesn't move. If the user had
/// scrolled into the sliver, it lands on its start instead: what was in
/// view there has changed too.
class SliverAnchor {
  /// Goes on the sliver to keep in place.
  final GlobalKey key = GlobalKey(debugLabel: 'SliverAnchor');

  double? _heldOffset;

  /// Remembers where the sliver starts, for the next frame only.
  void hold() {
    _heldOffset = _scrollOffset;
    if (_heldOffset == null) return;
    // Let go once the change is on screen, so a later one (e.g. a liked
    // station joining Favorite) gets the physics' usual treatment.
    SchedulerBinding.instance.addPostFrameCallback((_) => _heldOffset = null);
  }

  /// The scroll position that keeps the sliver in place, given the one
  /// before the change, or null when nothing is held. Lets go of the hold.
  double? takePosition(double pixels) {
    final from = _heldOffset;
    _heldOffset = null;
    final to = _scrollOffset;
    if (from == null || to == null) return null;
    return math.min(pixels, from) + to - from;
  }

  /// How far down the scroll view the sliver starts, as last laid out.
  double? get _scrollOffset {
    final sliver = key.currentContext?.findRenderObject();
    if (sliver is! RenderSliver || sliver.geometry == null) return null;
    return sliver.constraints.precedingScrollExtent;
  }
}

/// Keeps the rows in view where they are on screen while rows grow or
/// shrink, e.g. while a hidden station's slot closes: the rows below it
/// move up and the ones above it stay.
///
/// The physics would otherwise keep the distance to the end of the list,
/// which pulls the rows above down instead. Worse, a list with a row part
/// way grown or shrunk only estimates its length, and the estimate changes
/// with every layout the physics' own move causes, so the list ran away.
///
/// Rows [attach] themselves. Call [hold] right before a change, and on
/// every frame of one that plays out: the layout that shows it scrolls by
/// as much as the first row in view moved. At the top of the list nothing
/// is held, so a row coming back there pushes the others down.
class RowScrollAnchor {
  final Set<BuildContext> _rows = {};

  /// The rows in view when held, top first, with their scroll offsets.
  List<(BuildContext, double)>? _held;

  /// The scroll position the held frame's layout started from.
  double? _from;

  /// Makes [row] one of the rows kept in place, while it is in the tree.
  void attach(BuildContext row) => _rows.add(row);

  /// Takes [row] out of the rows kept in place: it left the tree, so it
  /// can't be measured any more, even before it is disposed.
  void detach(BuildContext row) => _rows.remove(row);

  /// Remembers where the rows in view are, until the frame is drawn.
  ///
  /// Holds once per frame: the first call is the one made before the
  /// change, from the layout still on screen.
  void hold() {
    if (_held != null) return;
    final held = <(BuildContext, double)>[];
    for (final row in _rows) {
      final box = row.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final viewport = RenderAbstractViewport.maybeOf(box);
      final top = _scrollOffsetOf(box);
      if (viewport is! RenderViewportBase ||
          !viewport.offset.hasPixels ||
          top == null) {
        continue;
      }
      final pixels = viewport.offset.pixels;
      final inView = top + box.size.height > pixels &&
          top < pixels + viewport.size.height;
      if (inView) held.add((row, top));
    }
    held.sort((a, b) => a.$2.compareTo(b.$2));
    _held = held;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _held = null;
      _from = null;
    });
  }

  /// The scroll position that keeps the first held row still on screen,
  /// or null when nothing is held. The same in every layout of the frame,
  /// so the layouts the move causes settle on it.
  double? takePosition(ScrollMetrics oldPosition, ScrollMetrics newPosition) {
    final held = _held;
    if (held == null || oldPosition.pixels <= oldPosition.minScrollExtent) {
      return null;
    }
    // The first row still there: a hidden one left the tree once its slot
    // closed, in this very frame maybe, and the row after it took its
    // place.
    for (final (row, top) in held) {
      if (!_rows.contains(row)) continue;
      final box = row.findRenderObject();
      final now = box == null || !box.attached ? null : _scrollOffsetOf(box);
      if (now == null) continue;
      final from = _from ??= newPosition.pixels;
      return from + now - top;
    }
    return null;
  }

  /// How far down the scroll view [row] starts. Reads no sizes, so it also
  /// works while the viewport lays out.
  static double? _scrollOffsetOf(RenderObject row) {
    var offset = 0.0;
    var child = row;
    for (var parent = row.parent; parent != null; parent = parent.parent) {
      switch (parent) {
        case RenderViewportBase():
          return child is RenderSliver
              ? child.constraints.precedingScrollExtent + offset
              : null;
        case RenderSliver():
          offset += parent.childScrollOffset(child) ?? 0;
        default:
          if (child.parentData case final BoxParentData data) {
            offset += data.offset.dy;
          }
      }
      child = parent;
    }
    return null;
  }
}
