import 'package:flutter/widgets.dart';

/// A [ScrollController] whose mouse wheel glides instead of jumping.
///
/// Flutter moves a list by a wheel notch's whole step at once, which reads
/// as stutter on a desktop. Here each notch animates the step, and notches
/// that come while one still glides add to where it is going, so a spun
/// wheel moves on smoothly and stops where the notches add up to. The
/// trackpad, drags and the keyboard scroll as before.
class DesktopScrollController extends ScrollController {
  DesktopScrollController({super.debugLabel});

  /// How long one notch takes to glide.
  static const Duration glideDuration = Duration(milliseconds: 220);

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _GlidingScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class _GlidingScrollPosition extends ScrollPositionWithSingleContext {
  _GlidingScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// Where the wheel's glide is going, while it glides.
  double? _glideTarget;

  @override
  void pointerScroll(double delta) {
    if (delta == 0) return;
    // A glide under way goes on from where it was heading, so quick notches
    // add up rather than each starting over from the current pixels.
    final gliding = _glideTarget != null && activity is DrivenScrollActivity;
    final from = gliding ? _glideTarget! : pixels;
    final target = (from + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) return;
    _glideTarget = target;
    animateTo(
      target,
      duration: DesktopScrollController.glideDuration,
      curve: Curves.easeOutCubic,
    ).whenComplete(() {
      if (_glideTarget == target) _glideTarget = null;
    });
  }
}
