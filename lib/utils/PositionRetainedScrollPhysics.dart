import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

class PositionRetainedScrollPhysics extends ScrollPhysics {
  final bool shouldRetain;

  /// Keeps its sliver in place across a change it was told to hold for.
  final SliverAnchor? anchor;

  const PositionRetainedScrollPhysics({
    super.parent,
    this.shouldRetain = true,
    this.anchor,
  });

  @override
  PositionRetainedScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return PositionRetainedScrollPhysics(
      parent: buildParent(ancestor),
      shouldRetain: shouldRetain,
      anchor: anchor,
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

    final anchored = anchor?.takePosition(oldPosition.pixels);
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
