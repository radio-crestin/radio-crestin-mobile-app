import 'dart:async';

/// Decides when the car screen shows its no-internet alert.
///
/// On the road the internet drops often and briefly: tunnels, cell
/// handoffs, leaving the home WiFi. The buffer plays through most drops
/// and playback reconnects on its own, so a modal alert the driver has to
/// tap away would only distract. It shows once an outage has lasted
/// [delay] with the car connected, and goes as soon as the internet is
/// back.
class OfflineAlertGate {
  OfflineAlertGate({
    required this.show,
    required this.dismiss,
    this.delay = const Duration(seconds: 5),
  });

  /// Shows the alert.
  final void Function() show;

  /// Takes the alert down, if it is up.
  final void Function() dismiss;

  final Duration delay;

  bool _offline = false;
  bool _carConnected = false;
  Timer? _timer;

  /// The internet went out ([offline]) or came back.
  void onOfflineChanged(bool offline) {
    if (offline == _offline) return;
    _offline = offline;
    if (offline) {
      _arm();
    } else {
      _timer?.cancel();
      dismiss();
    }
  }

  /// The car connected or disconnected. Connecting while already offline
  /// waits the full [delay] too: leaving home, the phone often switches
  /// from WiFi to mobile data right as the car connects.
  void onCarConnectedChanged(bool connected) {
    if (connected == _carConnected) return;
    _carConnected = connected;
    if (connected) {
      if (_offline) _arm();
    } else {
      _timer?.cancel();
    }
  }

  void _arm() {
    if (!_carConnected || (_timer?.isActive ?? false)) return;
    _timer = Timer(delay, () {
      if (_offline && _carConnected) show();
    });
  }

  void dispose() => _timer?.cancel();
}
