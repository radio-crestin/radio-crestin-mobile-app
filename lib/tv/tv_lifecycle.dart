import 'package:flutter/widgets.dart';

/// The non-UI work an app lifecycle transition calls for in the TV and
/// desktop shells.
enum TvLifecycleAction {
  /// Nothing to do: a focus change or an intermediate state.
  none,

  /// The app is visible again after being hidden or backgrounded.
  returnedToForeground,

  /// The app moved to the background.
  enteredBackground,

  /// The Flutter engine is detaching from the app.
  detached,
}

/// Turns app lifecycle transitions into [TvLifecycleAction]s.
///
/// Flutter reports every intermediate state (`paused → hidden → inactive →
/// resumed`), and on desktop `inactive ↔ resumed` fires on every window
/// focus change. A return to the foreground is therefore reported only when
/// the app was really hidden or paused in between, so focusing the window
/// does not trigger a station sync and reconnect check.
class TvLifecycleTracker {
  bool _away = false;

  /// Records [state] and returns the work it calls for.
  TvLifecycleAction onTransition(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
        _away = true;
        return TvLifecycleAction.none;
      case AppLifecycleState.paused:
        _away = true;
        return TvLifecycleAction.enteredBackground;
      case AppLifecycleState.resumed:
        final wasAway = _away;
        _away = false;
        return wasAway
            ? TvLifecycleAction.returnedToForeground
            : TvLifecycleAction.none;
      case AppLifecycleState.inactive:
        return TvLifecycleAction.none;
      case AppLifecycleState.detached:
        return TvLifecycleAction.detached;
    }
  }
}
