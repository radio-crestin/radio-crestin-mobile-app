import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

const wifi = [ConnectivityResult.wifi];
const mobile = [ConnectivityResult.mobile];
const none = [ConnectivityResult.none];

/// Stands in for the `connectivity_plus` plugin: tests set the current
/// network and emit changes.
class FakeConnectivity implements Connectivity {
  FakeConnectivity(this.current);

  List<ConnectivityResult> current;
  final _changes = StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => current;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _changes.stream;

  /// Whether anything still listens for changes.
  bool get hasListener => _changes.hasListener;

  void emit(List<ConnectivityResult> results) {
    current = results;
    _changes.add(results);
  }
}
