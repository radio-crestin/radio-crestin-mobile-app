import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:mobx/mobx.dart';

import '../components/NotificationBanner.dart';

part 'app_settings_store.g.dart';

typedef ConnectivityRestoredCallback = Future<void> Function();

class AppStore = _AppStore with _$AppStore;

abstract class _AppStore with Store {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  ConnectivityRestoredCallback? onConnectivityRestored;

  _AppStore();

  @observable
  bool hasInternetConnection = true;

  @observable
  bool showNotification = false;

  @observable
  NotificationType? currentNotificationType;

  @observable
  String? currentNotificationMessage;

  @action
  void setInternetConnection(bool value) {
    final previousState = hasInternetConnection;
    hasInternetConnection = value;

    if (!value) {
      setNotification(NotificationType.network);
    } else if (!previousState && value) {
      setNotification(NotificationType.networkRestored);
      onConnectivityRestored?.call();
    }
  }

  @action
  void setNotification(
    NotificationType notificationType, {
    String? customMessage,
  }) {
    currentNotificationType = notificationType;
    currentNotificationMessage = customMessage;
    showNotification = true;
  }

  @action
  void clearNotification() {
    showNotification = false;
    currentNotificationType = null;
    currentNotificationMessage = null;
  }

  @action
  void handleError(dynamic error) {
    if (showNotification && currentNotificationType == NotificationType.network)
      return;

    debugPrint('Error: $error');
    debugPrint('StackTrace.current: ${StackTrace.current}');

    if (_isInternetError(error)) {
      setNotification(NotificationType.network);
    } else if (_isAuthError(error)) {
      setNotification(NotificationType.authentication);
    } else if (_isServerError(error)) {
      setNotification(NotificationType.error);
    } else {
      setNotification(NotificationType.error);
    }
  }

  bool _isAuthError(dynamic error) {
    final errorString = error.toString().toLowerCase();
    return errorString.contains('auth') || 
           errorString.contains('unauthorized') ||
           errorString.contains('forbidden') ||
           errorString.contains('401') ||
           errorString.contains('403');
  }

  bool _isServerError(dynamic error) {
    final errorString = error.toString().toLowerCase();
    return errorString.contains('500') || 
           errorString.contains('502') ||
           errorString.contains('503') ||
           errorString.contains('504') ||
           errorString.contains('server');
  }

  bool _isInternetError(dynamic error) {
    final errorString = error.toString().toLowerCase();
    
    // Check for iOS-specific network error codes
    final iosNetworkErrors = ['-1001', '-1003', '-1004', '-1005', '-1008', '-1009', '-11800'];
    for (final code in iosNetworkErrors) {
      if (errorString.contains(code)) return true;
    }
    
    // Check for Android/general network error patterns
    return errorString.contains('network') || 
           errorString.contains('internet') ||
           errorString.contains('connection') ||
           errorString.contains('socket') ||
           errorString.contains('timeout') ||
           errorString.contains('no address associated with hostname') ||
           errorString.contains('failed host lookup') ||
           errorString.contains('clientexception') ||
           errorString.contains('socketexception') ||
           errorString.contains('cannot connect to host') ||
           errorString.contains('connection refused') ||
           errorString.contains('connection reset') ||
           errorString.contains('connection timed out') ||
           errorString.contains('unreachable') ||
           errorString.contains('unknownhostexception') ||
           errorString.contains('unable to resolve host') ||
           errorString.contains('source error');
  }

  @action
  Future<void> initConnectivity() async {
    hasInternetConnection = await checkConnection();
    monitorConnection();
  }

  @action
  Future<bool> checkConnection() async {
    final results = await _connectivity.checkConnectivity();
    return results.isNotEmpty &&
        !results.every((result) => result == ConnectivityResult.none);
  }

  @action
  void monitorConnection() {
    _subscription?.cancel();
    _subscription = _connectivity.onConnectivityChanged.listen((results) {
      final hasConnection =
          results.isNotEmpty &&
          !results.every((result) => result == ConnectivityResult.none);
      setInternetConnection(hasConnection);
    });
  }

  void dispose() {
    _subscription?.cancel();
  }
}