import 'dart:async';
import 'dart:developer' as developer;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:rxdart/rxdart.dart';

class NetworkService {
  static NetworkService get instance => _instance!;
  static NetworkService? _instance;

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  final BehaviorSubject<bool> isOnMobileData = BehaviorSubject.seeded(false);
  final BehaviorSubject<bool> isOffline = BehaviorSubject.seeded(false);

  NetworkService() {
    _instance = this;
  }

  Future<void> initialize() async {
    try {
      final results = await _connectivity.checkConnectivity();
      _updateFromResults(results);
    } catch (e) {
      developer.log('NetworkService: initial check failed: $e');
    }

    _subscription = _connectivity.onConnectivityChanged.listen((results) {
      _updateFromResults(results);
    });
  }

  void _updateFromResults(List<ConnectivityResult> results) {
    final mobile = results.contains(ConnectivityResult.mobile);
    final wifi = results.contains(ConnectivityResult.wifi);
    final ethernet = results.contains(ConnectivityResult.ethernet);
    final none = results.contains(ConnectivityResult.none);

    // Offline if only ConnectivityResult.none or empty results (iOS transition)
    final offline = results.isEmpty || (none && !mobile && !wifi && !ethernet);
    if (offline != isOffline.value) {
      developer.log('NetworkService: isOffline = $offline');
      isOffline.add(offline);
    }

    // On mobile data only if mobile is present AND wifi/ethernet is not
    final onMobile = mobile && !wifi && !ethernet;
    if (onMobile != isOnMobileData.value) {
      developer.log('NetworkService: isOnMobileData = $onMobile');
      isOnMobileData.add(onMobile);
    }
  }

  void dispose() {
    _subscription?.cancel();
    isOnMobileData.close();
    isOffline.close();
  }
}
