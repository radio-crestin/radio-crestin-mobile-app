// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_settings_store.dart';

// **************************************************************************
// StoreGenerator
// **************************************************************************

// ignore_for_file: non_constant_identifier_names, unnecessary_brace_in_string_interps, unnecessary_lambdas, prefer_expression_function_bodies, lines_longer_than_80_chars, avoid_as, avoid_annotating_with_dynamic, no_leading_underscores_for_local_identifiers

mixin _$AppStore on _AppStore, Store {
  late final _$hasInternetConnectionAtom =
      Atom(name: '_AppStore.hasInternetConnection', context: context);

  @override
  bool get hasInternetConnection {
    _$hasInternetConnectionAtom.reportRead();
    return super.hasInternetConnection;
  }

  @override
  set hasInternetConnection(bool value) {
    _$hasInternetConnectionAtom.reportWrite(value, super.hasInternetConnection,
        () {
      super.hasInternetConnection = value;
    });
  }

  late final _$showNotificationAtom =
      Atom(name: '_AppStore.showNotification', context: context);

  @override
  bool get showNotification {
    _$showNotificationAtom.reportRead();
    return super.showNotification;
  }

  @override
  set showNotification(bool value) {
    _$showNotificationAtom.reportWrite(value, super.showNotification, () {
      super.showNotification = value;
    });
  }

  late final _$currentNotificationTypeAtom =
      Atom(name: '_AppStore.currentNotificationType', context: context);

  @override
  NotificationType? get currentNotificationType {
    _$currentNotificationTypeAtom.reportRead();
    return super.currentNotificationType;
  }

  @override
  set currentNotificationType(NotificationType? value) {
    _$currentNotificationTypeAtom
        .reportWrite(value, super.currentNotificationType, () {
      super.currentNotificationType = value;
    });
  }

  late final _$currentNotificationMessageAtom =
      Atom(name: '_AppStore.currentNotificationMessage', context: context);

  @override
  String? get currentNotificationMessage {
    _$currentNotificationMessageAtom.reportRead();
    return super.currentNotificationMessage;
  }

  @override
  set currentNotificationMessage(String? value) {
    _$currentNotificationMessageAtom
        .reportWrite(value, super.currentNotificationMessage, () {
      super.currentNotificationMessage = value;
    });
  }

  late final _$initConnectivityAsyncAction =
      AsyncAction('_AppStore.initConnectivity', context: context);

  @override
  Future<void> initConnectivity() {
    return _$initConnectivityAsyncAction.run(() => super.initConnectivity());
  }

  late final _$checkConnectionAsyncAction =
      AsyncAction('_AppStore.checkConnection', context: context);

  @override
  Future<bool> checkConnection() {
    return _$checkConnectionAsyncAction.run(() => super.checkConnection());
  }

  late final _$_AppStoreActionController =
      ActionController(name: '_AppStore', context: context);

  @override
  void setInternetConnection(bool value) {
    final _$actionInfo = _$_AppStoreActionController.startAction(
        name: '_AppStore.setInternetConnection');
    try {
      return super.setInternetConnection(value);
    } finally {
      _$_AppStoreActionController.endAction(_$actionInfo);
    }
  }

  @override
  void setNotification(NotificationType notificationType,
      {String? customMessage}) {
    final _$actionInfo = _$_AppStoreActionController.startAction(
        name: '_AppStore.setNotification');
    try {
      return super
          .setNotification(notificationType, customMessage: customMessage);
    } finally {
      _$_AppStoreActionController.endAction(_$actionInfo);
    }
  }

  @override
  void clearNotification() {
    final _$actionInfo = _$_AppStoreActionController.startAction(
        name: '_AppStore.clearNotification');
    try {
      return super.clearNotification();
    } finally {
      _$_AppStoreActionController.endAction(_$actionInfo);
    }
  }

  @override
  void handleError(dynamic error) {
    final _$actionInfo =
        _$_AppStoreActionController.startAction(name: '_AppStore.handleError');
    try {
      return super.handleError(error);
    } finally {
      _$_AppStoreActionController.endAction(_$actionInfo);
    }
  }

  @override
  void monitorConnection() {
    final _$actionInfo = _$_AppStoreActionController.startAction(
        name: '_AppStore.monitorConnection');
    try {
      return super.monitorConnection();
    } finally {
      _$_AppStoreActionController.endAction(_$actionInfo);
    }
  }

  @override
  String toString() {
    return '''
hasInternetConnection: ${hasInternetConnection},
showNotification: ${showNotification},
currentNotificationType: ${currentNotificationType},
currentNotificationMessage: ${currentNotificationMessage}
    ''';
  }
}
