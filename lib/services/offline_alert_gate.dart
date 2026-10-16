import 'dart:async';

/// Decides when the car screen shows its no-internet alert: CarPlay's
/// modal alert, Android Auto's error in place of the player.
///
/// On the road the internet drops often and briefly: tunnels, cell
/// handoffs, leaving the home WiFi. The forward buffer (5 minutes in the
/// car) plays most drops through and playback reconnects on its own, so a modal
/// alert the driver has to tap away would only distract. It shows once the
/// internet has been out for [delay] with the car connected and no audio
/// coming out, and goes as soon as the internet or the audio is back. Once
/// tapped away it stays away, unless the driver asks for audio again.
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
  bool _audioPlaying = false;
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
  /// from WiFi to mobile data right as the car connects. The alert belongs
  /// to the car screen and goes with it.
  void onCarConnectedChanged(bool connected) {
    if (connected == _carConnected) return;
    _carConnected = connected;
    if (connected) {
      if (_offline) _arm();
    } else {
      _timer?.cancel();
      dismiss();
    }
  }

  /// Audio is coming out ([playing]) or stopped. While the buffer plays an
  /// outage through there is nothing to tell the driver; once the audio
  /// stops, the alert follows after [delay].
  void onAudioPlayingChanged(bool playing) {
    if (playing == _audioPlaying) return;
    _audioPlaying = playing;
    if (playing) {
      _timer?.cancel();
      if (_offline) dismiss();
    } else if (_offline) {
      _arm();
    }
  }

  /// The driver asked for audio: play, next, previous or a station pick.
  /// Without internet nothing changes for the gate (the audio was already
  /// stopped), yet the driver waits for an answer: the alert comes again
  /// after [delay], even if they had tapped it away. Each request starts
  /// the delay over, so skipping through stations is not interrupted.
  void onPlayRequested() {
    _timer?.cancel();
    if (_offline) _arm();
  }

  void _arm() {
    if (!_carConnected || _audioPlaying || (_timer?.isActive ?? false)) {
      return;
    }
    _timer = Timer(delay, () {
      if (_offline && _carConnected && !_audioPlaying) show();
    });
  }

  void dispose() => _timer?.cancel();
}
