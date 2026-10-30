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
  /// Creates a tracker; [hiddenIsBackground] is for desktop.
  ///
  /// A desktop engine never reports `paused` (macOS reports only `resumed`,
  /// `inactive` and `hidden`), so there the background is the window out
  /// of sight: minimized, closed with ⌘W, covered by other windows, or
  /// hidden with the app (⌘H), and the app is back as soon as the window is
  /// in sight again, at `inactive`. On Android TV `hidden` is only a step on
  /// the way to `paused`, which reports it.
  TvLifecycleTracker({this.hiddenIsBackground = false});

  /// Whether `hidden` already means the app is in the background.
  final bool hiddenIsBackground;

  bool _away = false;

  /// Records [state] and returns the work it calls for.
  TvLifecycleAction onTransition(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
        final wasAway = _away;
        _away = true;
        return hiddenIsBackground && !wasAway
            ? TvLifecycleAction.enteredBackground
            : TvLifecycleAction.none;
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
        // On desktop the window is back in sight: macOS reports one that
        // shows again while another app is in front (the window covering
        // it moved away) as `inactive`, and `resumed` only once it is
        // clicked.
        if (!hiddenIsBackground || !_away) return TvLifecycleAction.none;
        _away = false;
        return TvLifecycleAction.returnedToForeground;
      case AppLifecycleState.detached:
        return TvLifecycleAction.detached;
    }
  }
}
