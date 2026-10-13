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

  test('the online value replayed at start dismisses nothing', () {
    withGate((async, gate, _, dismissed) {
      gate.onOfflineChanged(false);

      expect(dismissed(), 0);
    });
  });
}
