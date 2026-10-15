import 'dart:async';

import 'package:flutter/foundation.dart';

import '../appAudioHandler.dart' show ConnectionErrorReason;
import '../services/network_service.dart' show ConnectionStatus;
import '../types/Station.dart';

/// What the status snackbar reports, highest priority first.
enum StatusKind {
  /// The listener just hid a station. Transient, with an undo.
  stationHidden,

  /// A station failed to play. Transient, with a retry.
  stationError,

  /// The internet is out of reach. Stays for as long as that lasts.
  offline,

  /// The internet just came back. Transient.
  backOnline,
}

/// The short, human reason a station failed to play.
String stationErrorReason(ConnectionErrorReason reason) => switch (reason) {
      ConnectionErrorReason.timeout => 'Conexiunea a expirat',
      ConnectionErrorReason.network => 'Verifică conexiunea la internet',
      ConnectionErrorReason.httpError => 'Stația nu este disponibilă momentan',
      ConnectionErrorReason.unknown => 'Nu răspunde momentan',
    };

/// One status for the snackbar, compared by what it shows.
@immutable
class StatusMessage {
  /// The internet is out of reach.
  ///
  /// [status] says why: no network at all, or a network without internet,
  /// which [onMobileData] names (WiFi or mobile data). [playIntent]: the
  /// listener wants audio, which then starts by itself once the internet is
  /// back. Without either explanation there is no body: the title alone.
  const StatusMessage.offline({
    required ConnectionStatus status,
    bool onMobileData = false,
    bool playIntent = false,
  })  : assert(status != ConnectionStatus.online),
        kind = StatusKind.offline,
        title = 'Nu ai conexiune la internet',
        body = status == ConnectionStatus.noInternet
            ? (onMobileData ? _noInternetOnMobileData : _noInternetOnWifi)
            : (playIntent ? _resumesByItself : null),
        station = null;

  /// The internet came back; [resuming]: playback continues with it.
  const StatusMessage.backOnline({required bool resuming})
      : kind = StatusKind.backOnline,
        title = 'Conectat din nou',
        body = resuming ? 'redarea continuă' : null,
        station = null;

  /// [stationTitle] failed to play, for [reason].
  StatusMessage.stationError({
    required String stationTitle,
    required ConnectionErrorReason reason,
    this.station,
  })  : kind = StatusKind.stationError,
        title = stationTitle,
        body = stationErrorReason(reason);

  /// The listener hid [station], which an undo shows again.
  StatusMessage.stationHidden({required Station this.station})
      : kind = StatusKind.stationHidden,
        title = station.displayTitle,
        body = 'Stație ascunsă. O poți readuce din Setări.';

  static const _noInternetOnWifi =
      'Ești conectat la WiFi, dar rețeaua nu are internet.';
  static const _noInternetOnMobileData =
      'Ești conectat la date mobile, dar rețeaua nu are internet.';
  static const _resumesByItself =
      'Redarea pornește singură când revine internetul.';

  /// Which status this is.
  final StatusKind kind;

  /// The first line: the status, or the station that failed.
  final String title;

  /// The explanation under [title]; for back online, the optional suffix.
  final String? body;

  /// The station that failed or was hidden, for its artwork. Null for
  /// network statuses.
  final Station? station;

  /// Whether the listener can swipe it away: a station error or a hidden
  /// station. Offline stays for as long as the internet is out, back online
  /// for its 3s.
  bool get isDismissible =>
      kind == StatusKind.stationError || kind == StatusKind.stationHidden;

  /// Identifies the visible content, so only real changes cross-fade.
  String get contentKey => '${kind.name}|$title|${body ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is StatusMessage &&
      other.kind == kind &&
      other.title == title &&
      other.body == body &&
      other.station?.id == station?.id;

  @override
  int get hashCode => Object.hash(kind, title, body, station?.id);
}

/// Decides what the status snackbar says, one status at a time: a station
/// just hidden, else a station error, else offline, else back online.
///
/// The page feeds it the network state (from `NetworkService`), connection
/// errors, playback, the current station and the stations hidden; it owns
/// the timers that end the transient statuses. It holds no widgets, so
/// tests drive it alone.
class StatusSnackbarController extends ChangeNotifier {
  /// Creates the controller; the durations are the design's.
  StatusSnackbarController({
    this.errorDuration = const Duration(seconds: 6),
    this.backOnlineDuration = const Duration(seconds: 3),
    this.hiddenDuration = const Duration(seconds: 6),
  });

  /// How long a station error stays, unless errors are held.
  final Duration errorDuration;

  /// How long "back online" stays.
  final Duration backOnlineDuration;

  /// How long a hidden station's undo stays, unless errors are held.
  final Duration hiddenDuration;

  static const _fallbackStationTitle = 'Stația radio';

  ConnectionStatus _network = ConnectionStatus.online;
  bool _onMobileData = false;
  bool _backOnline = false;
  bool _playIntent = false;
  bool _playingReady = false;
  bool _holdErrors = false;
  StatusMessage? _error;
  StatusMessage? _hidden;
  Timer? _errorTimer;
  Timer? _hiddenTimer;
  Timer? _backOnlineTimer;

  /// What the snackbar shows, or null for nothing.
  StatusMessage? get message {
    // The listener's own action answers first; what it covers shows again
    // once it goes.
    final hidden = _hidden;
    if (hidden != null) return hidden;
    final error = _error;
    if (error != null) return error;
    if (isOffline) {
      return StatusMessage.offline(
        status: _network,
        onMobileData: _onMobileData,
        playIntent: _playIntent,
      );
    }
    if (_backOnline) return StatusMessage.backOnline(resuming: _playIntent);
    return null;
  }

  /// Whether the internet is out of reach: no network, or a network without
  /// internet (`NetworkService.isOffline`).
  bool get isOffline => _network != ConnectionStatus.online;

  /// Whether the listener wants audio playing, which shapes the copy.
  set playIntent(bool value) => _update(() => _playIntent = value);

  /// Keeps station errors, and a hidden station's undo, until dismissed,
  /// acted on or replaced.
  ///
  /// Set while a screen reader runs: a timed message could vanish before
  /// the listener reaches it.
  set holdErrors(bool value) {
    if (value == _holdErrors) return;
    _holdErrors = value;
    if (_error != null) _armErrorTimer();
    if (_hidden != null) _armHiddenTimer();
  }

  /// Updates the network state, as `NetworkService` reports it: its
  /// [status] and whether the device is [onMobileData].
  ///
  /// Going offline removes any station error (never shown while offline);
  /// coming back shows "back online" for [backOnlineDuration]. A change
  /// between no network and no internet only changes the explanation.
  void updateNetwork(ConnectionStatus status, {required bool onMobileData}) {
    _update(() {
      final wasOffline = isOffline;
      _network = status;
      _onMobileData = onMobileData;
      if (isOffline == wasOffline) return;
      _backOnlineTimer?.cancel();
      if (isOffline) {
        _backOnline = false;
        _removeError();
      } else {
        _backOnline = true;
        _backOnlineTimer =
            Timer(backOnlineDuration, () => _update(() => _backOnline = false));
      }
    });
  }

  /// Updates the playback state: the listener's [playIntent], and whether
  /// audio is playing and ready ([playingReady]).
  ///
  /// Audio starting to play again ends the station error: it no longer
  /// applies.
  void updatePlayback({required bool playIntent, required bool playingReady}) {
    final recovered = playingReady && !_playingReady;
    _playingReady = playingReady;
    _update(() {
      _playIntent = playIntent;
      if (recovered) _removeError();
    });
  }

  /// The current station is now [stationId].
  ///
  /// An error belongs to the station that failed: with another one current
  /// it is out of date, and its retry would replay the wrong station.
  void updateCurrentStation(int? stationId) {
    final error = _error;
    if (error == null || error.station?.id == stationId) return;
    clearError();
  }

  /// Shows that [stationTitle] failed to play, replacing any older error
  /// and restarting its timer. Returns whether it is shown.
  ///
  /// Dropped while offline: the offline status already says why, and
  /// playback resumes on its own once the internet is back.
  bool showStationError({
    required String stationTitle,
    required ConnectionErrorReason reason,
    Station? station,
  }) {
    if (isOffline) return false;
    _error = StatusMessage.stationError(
      stationTitle: stationTitle.isEmpty ? _fallbackStationTitle : stationTitle,
      reason: reason,
      station: station,
    );
    _armErrorTimer();
    notifyListeners();
    return true;
  }

  /// Removes the station error: swiped away, retried, recovered or out of
  /// date. The network statuses are not affected.
  void clearError() => _update(_removeError);

  /// Shows that the listener hid [station], with an undo, replacing the
  /// one about an earlier station.
  void showStationHidden(Station station) {
    _hidden = StatusMessage.stationHidden(station: station);
    _armHiddenTimer();
    notifyListeners();
  }

  /// Removes the hidden station's undo: undone, swiped away or timed out.
  void clearStationHidden() => _update(_removeHidden);

  /// Removes the message on show when the listener swiped it away: the
  /// hidden station's undo or the station error.
  void dismiss() => _update(() {
        if (_hidden != null) {
          _removeHidden();
        } else {
          _removeError();
        }
      });

  /// Runs [change] and notifies listeners only when [message] changed.
  void _update(VoidCallback change) {
    final before = message;
    change();
    if (message != before) notifyListeners();
  }

  void _removeError() {
    _error = null;
    _errorTimer?.cancel();
  }

  void _armErrorTimer() {
    _errorTimer?.cancel();
    if (_holdErrors) return;
    _errorTimer = Timer(errorDuration, clearError);
  }

  void _removeHidden() {
    _hidden = null;
    _hiddenTimer?.cancel();
  }

  void _armHiddenTimer() {
    _hiddenTimer?.cancel();
    if (_holdErrors) return;
    _hiddenTimer = Timer(hiddenDuration, clearStationHidden);
  }

  @override
  void dispose() {
    _hiddenTimer?.cancel();
    _errorTimer?.cancel();
    _backOnlineTimer?.cancel();
    super.dispose();
  }
}
