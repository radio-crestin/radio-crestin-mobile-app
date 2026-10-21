import 'package:flutter/widgets.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

/// Records PostHog's `$screen` events once a page transition has finished.
///
/// On Android the plugin call runs on the main thread, which also draws
/// Flutter's frames, and took ~20 ms there on a moto g7 plus: a dropped
/// frame at the start of the page change.
class PosthogScreenObserver extends PosthogObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _afterTransition(route, () => super.didPush(route, previousRoute));

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _afterTransition(route, () => super.didPop(route, previousRoute));

  void _afterTransition(Route<dynamic> route, VoidCallback record) {
    if (route is! ModalRoute) return record();
    final animation = route.animation;
    if (animation == null || !animation.isAnimating) return record();
    void onStatusChanged(AnimationStatus status) {
      // While heroes are measured the page is offstage for a moment, and
      // its animation reads as complete.
      if (status.isAnimating || route.offstage) return;
      animation.removeStatusListener(onStatusChanged);
      record();
    }

    animation.addStatusListener(onStatusChanged);
  }
}
