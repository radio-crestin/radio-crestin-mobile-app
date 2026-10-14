import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/offline_alert_gate.dart';

/// When the car screen shows its no-internet alert: only for an outage
/// that lasts, and never for the short drops of the road. On fake time.
void main() {
  const delay = Duration(seconds: 5);
  const moment = Duration(milliseconds: 1);

  /// Runs [body] with a gate on fake time, its car connected, counting
  /// how often it showed and dismissed the alert.
  void withGate(
      void Function(FakeAsync async, OfflineAlertGate gate,
              int Function() shown, int Function() dismissed)
          body) {
    fakeAsync((async) {
      var shown = 0;
      var dismissed = 0;
      final gate = OfflineAlertGate(
        show: () => shown++,
        dismiss: () => dismissed++,
        delay: delay,
      )..onCarConnectedChanged(true);
      body(async, gate, () => shown, () => dismissed);
      gate.dispose();
    });
  }

  test('a short drop shows nothing', () {
    withGate((async, gate, shown, _) {
      gate.onOfflineChanged(true);
      async.elapse(delay - moment);
      gate.onOfflineChanged(false);
      async.elapse(delay * 2);

      expect(shown(), 0);
    });
  });

  test('an outage that lasts shows the alert once, then takes it down', () {
    withGate((async, gate, shown, dismissed) {
      gate.onOfflineChanged(true);
      async.elapse(delay);
      expect(shown(), 1);

      gate.onOfflineChanged(false);
      expect(dismissed(), 1);
    });
  });

  test('the alert does not come back after the driver tapped it away', () {
    withGate((async, gate, shown, _) {
      gate.onOfflineChanged(true);
      async.elapse(delay);
      gate.onOfflineChanged(true);
      gate.onCarConnectedChanged(true);
      async.elapse(delay * 2);

      expect(shown(), 1);
    });
  });

  test('connecting the car while offline waits the delay too', () {
    withGate((async, gate, shown, _) {
      gate.onCarConnectedChanged(false);
      gate.onOfflineChanged(true);
      async.elapse(delay * 2);
      expect(shown(), 0, reason: 'no car, no alert');

      gate.onCarConnectedChanged(true);
      async.elapse(delay - moment);
      expect(shown(), 0, reason: 'not on connect itself');

      async.elapse(moment);
      expect(shown(), 1);
    });
  });

  test('reconnecting the car during the delay starts it over', () {
    withGate((async, gate, shown, _) {
      gate.onOfflineChanged(true);
      async.elapse(delay - moment);
      gate.onCarConnectedChanged(false);
      gate.onCarConnectedChanged(true);
      async.elapse(delay - moment);
      expect(shown(), 0);

      async.elapse(moment);
      expect(shown(), 1);
    });
  });

  test('disconnecting the car cancels a pending alert', () {
    withGate((async, gate, shown, _) {
      gate.onOfflineChanged(true);
      gate.onCarConnectedChanged(false);
      async.elapse(delay * 2);

      expect(shown(), 0);
    });
  });

  test('disconnecting the car takes the alert down with it', () {
    withGate((async, gate, shown, dismissed) {
      gate.onOfflineChanged(true);
      async.elapse(delay);
      expect(shown(), 1);

      gate.onCarConnectedChanged(false);
      expect(dismissed(), 1);

      // The next drive, still offline: the alert comes again.
      gate.onCarConnectedChanged(true);
      async.elapse(delay);
      expect(shown(), 2);
    });
  });

  test('an outage the buffer plays through shows nothing', () {
    withGate((async, gate, shown, _) {
      gate.onAudioPlayingChanged(true);
      gate.onOfflineChanged(true);
      async.elapse(const Duration(minutes: 2));
      gate.onOfflineChanged(false);

      expect(shown(), 0);
    });
  });

  test('the alert follows once the buffer runs out', () {
    withGate((async, gate, shown, _) {
      gate.onAudioPlayingChanged(true);
      gate.onOfflineChanged(true);
      async.elapse(const Duration(minutes: 1));
      gate.onAudioPlayingChanged(false);
      async.elapse(delay - moment);
      expect(shown(), 0, reason: 'a rebuffer may end on its own');

      async.elapse(moment);
      expect(shown(), 1);
    });
  });

  test('a short rebuffer while offline shows nothing', () {
    withGate((async, gate, shown, _) {
      gate.onAudioPlayingChanged(true);
      gate.onOfflineChanged(true);
      gate.onAudioPlayingChanged(false);
      async.elapse(delay - moment);
      gate.onAudioPlayingChanged(true);
      async.elapse(delay * 2);

      expect(shown(), 0);
    });
  });

  test('audio coming back takes the alert down', () {
    withGate((async, gate, shown, dismissed) {
      gate.onOfflineChanged(true);
      async.elapse(delay);
      expect(shown(), 1, reason: 'nothing playing: the alert explains why');

      gate.onAudioPlayingChanged(true);
      expect(dismissed(), 1);
    });
  });

  group('a play request (play, next, previous, station pick)', () {
    /// Offline with nothing playing, the alert shown and tapped away.
    void afterAlertTappedAway(FakeAsync async, OfflineAlertGate gate,
        int Function() shown) {
      gate.onOfflineChanged(true);
      async.elapse(delay);
      expect(shown(), 1);
    }

    test('brings the alert back after the driver tapped it away', () {
      withGate((async, gate, shown, _) {
        afterAlertTappedAway(async, gate, shown);

        gate.onPlayRequested();
        async.elapse(delay - moment);
        expect(shown(), 1, reason: 'the station may still answer');

        async.elapse(moment);
        expect(shown(), 2);
      });
    });

    test('starts the delay over, so skipping is not interrupted', () {
      withGate((async, gate, shown, _) {
        afterAlertTappedAway(async, gate, shown);

        gate.onPlayRequested();
        async.elapse(delay - moment);
        gate.onPlayRequested();
        async.elapse(delay - moment);
        expect(shown(), 1);

        async.elapse(moment);
        expect(shown(), 2);
      });
    });

    test('shows nothing once the audio plays (a resume from the buffer)', () {
      withGate((async, gate, shown, _) {
        afterAlertTappedAway(async, gate, shown);

        gate.onPlayRequested();
        gate.onAudioPlayingChanged(true);
        async.elapse(delay * 2);

        expect(shown(), 1);
      });
    });

    test('shows nothing while the buffer plays, then the outage rule', () {
      withGate((async, gate, shown, _) {
        gate.onAudioPlayingChanged(true);
        gate.onOfflineChanged(true);
        gate.onPlayRequested();
        async.elapse(delay * 2);
        expect(shown(), 0, reason: 'audio still comes out');

        // The switch stops the buffered audio of the last station.
        gate.onAudioPlayingChanged(false);
        async.elapse(delay);
        expect(shown(), 1);
      });
    });

    test('shows nothing with internet or without the car', () {
      withGate((async, gate, shown, _) {
        gate.onPlayRequested();
        async.elapse(delay * 2);
        expect(shown(), 0, reason: 'online');

        gate.onCarConnectedChanged(false);
        gate.onOfflineChanged(true);
        gate.onPlayRequested();
        async.elapse(delay * 2);
        expect(shown(), 0, reason: 'no car');
      });
    });
  });

  test('the online value replayed at start dismisses nothing', () {
    withGate((async, gate, _, dismissed) {
      gate.onOfflineChanged(false);

      expect(dismissed(), 0);
    });
  });
}
