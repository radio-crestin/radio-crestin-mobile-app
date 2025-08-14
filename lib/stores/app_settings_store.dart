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

    if (_isAuthError(error)) {
      setNotification(NotificationType.authentication);
    } else if (_isServerError(error)) {
      setNotification(NotificationType.error);
    } else if (_isInternetError(error)) {
      setNotification(NotificationType.network);
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
    return errorString.contains('network') || 
           errorString.contains('internet') ||
           errorString.contains('connection') ||
           errorString.contains('socket') ||
           errorString.contains('timeout') ||
           errorString.contains('no address associated with hostname') ||
           errorString.contains('failed host lookup') ||
           errorString.contains('clientexception') ||
           errorString.contains('socketexception');
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