import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/tv/tv_lifecycle.dart';

/// Tests for [TvLifecycleTracker], which maps the lifecycle transitions the
/// TV and desktop shells receive onto the work `HomePage` does on mobile.
///
/// Flutter delivers every intermediate state, so a return from the
/// background arrives as `hidden → inactive → resumed`; the sequences below
/// mirror what `ServicesBinding` generates.
void main() {
  List<TvLifecycleAction> replay(
    TvLifecycleTracker tracker,
    List<AppLifecycleState> states,
  ) =>
      [for (final s in states) tracker.onTransition(s)];

  group('TvLifecycleTracker', () {
    test('HOME then back: background once, foreground once', () {
      final tracker = TvLifecycleTracker();

      final away = replay(tracker, const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      expect(away, const [
        TvLifecycleAction.none,
        TvLifecycleAction.none,
        TvLifecycleAction.enteredBackground,
      ]);

      final back = replay(tracker, const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(back, const [
        TvLifecycleAction.none,
        TvLifecycleAction.none,
        TvLifecycleAction.returnedToForeground,
      ]);
    });

    test('desktop window focus changes do nothing', () {
      final tracker = TvLifecycleTracker();
      final actions = replay(tracker, const [
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(actions, everyElement(TvLifecycleAction.none));
    });

    test('desktop minimise and restore counts as a return', () {
      final tracker = TvLifecycleTracker();
      final actions = replay(tracker, const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(actions.last, TvLifecycleAction.returnedToForeground);
      expect(actions.take(3), everyElement(TvLifecycleAction.none));
    });

    test('the return is reported only once', () {
      final tracker = TvLifecycleTracker();
      replay(tracker, const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      final again = replay(tracker, const [
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(again, everyElement(TvLifecycleAction.none));
    });

    test('detached is reported', () {
      final tracker = TvLifecycleTracker();
      expect(tracker.onTransition(AppLifecycleState.detached),
          TvLifecycleAction.detached);
    });
  });

  // The macOS engine reports only resumed, inactive and hidden: a window
  // minimized, closed with ⌘W, covered or hidden with the app is `hidden`,
  // and `paused` never comes.
  group('TvLifecycleTracker on desktop', () {
    TvLifecycleTracker desktop() =>
        TvLifecycleTracker(hiddenIsBackground: true);

    test('hiding the window is the background, once', () {
      final tracker = desktop();
      final away = replay(tracker, const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
      ]);
      expect(away, const [
        TvLifecycleAction.none,
        TvLifecycleAction.enteredBackground,
      ]);
      expect(tracker.onTransition(AppLifecycleState.hidden),
          TvLifecycleAction.none);
    });

    test('showing it again is a return to the foreground, once', () {
      final tracker = desktop();
      final actions = replay(tracker, const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(actions, const [
        TvLifecycleAction.none,
        TvLifecycleAction.enteredBackground,
        TvLifecycleAction.returnedToForeground,
        TvLifecycleAction.none,
      ]);
    });

    test('a window back in sight behind another app is back', () {
      // Uncovered while another app stays in front: the engine reports
      // `inactive`, and `resumed` only once the window is clicked.
      final tracker = desktop();
      final actions = replay(tracker, const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
      ]);
      expect(actions.last, TvLifecycleAction.returnedToForeground);

      // Clicking it later, or focus changes, start nothing more.
      final later = replay(tracker, const [
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(later, everyElement(TvLifecycleAction.none));

      // Covered again: the background again.
      expect(tracker.onTransition(AppLifecycleState.hidden),
          TvLifecycleAction.enteredBackground);
    });

    test('every hide after a return is reported again', () {
      final tracker = desktop();
      replay(tracker, const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      final again = replay(tracker, const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
      ]);
      expect(again.last, TvLifecycleAction.enteredBackground);
    });

    test('focus changes still do nothing', () {
      final tracker = desktop();
      final actions = replay(tracker, const [
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(actions, everyElement(TvLifecycleAction.none));
    });

    test('Android TV keeps waiting for paused', () {
      // The default tracker, as TvShell builds it off desktop.
      final actions = replay(TvLifecycleTracker(), const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
      ]);
      expect(actions, everyElement(TvLifecycleAction.none));
    });
  });
}
