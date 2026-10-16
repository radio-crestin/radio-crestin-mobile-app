import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../seek_mode_manager.dart';
import 'network_service.dart';

/// The device's state, merged under every info+ log record (see
/// `AnalyticsService.setLogContextProvider`).
///
/// A record then reads on its own: a stall on mobile data with the phone
/// locked in the car is a different problem from one on Wi-Fi with the app
/// open, and a log file sent by a listener shows which it was.
abstract final class LogContext {
  /// The live state. Reads values the services already hold, so it is
  /// cheap enough for every record.
  static Map<String, Object> current() {
    final network = NetworkService.instance;
    return build(
      status: network.status.value,
      onMobileData: network.isOnMobileData.value,
      appState: SchedulerBinding.instance.lifecycleState,
      carConnected: SeekModeManager.isCarConnected,
      seekOffset: SeekModeManager.currentOffset,
    );
  }

  /// The context attributes for the given state. Pure — unit tested
  /// directly.
  @visibleForTesting
  static Map<String, Object> build({
    required ConnectionStatus status,
    required bool onMobileData,
    required AppLifecycleState? appState,
    required bool carConnected,
    required Duration seekOffset,
  }) =>
      {
        'network': switch (status) {
          ConnectionStatus.online => 'online',
          ConnectionStatus.offline => 'offline',
          ConnectionStatus.noInternet => 'no_internet',
        },
        'on_mobile_data': onMobileData,
        'app_state': appState?.name ?? 'unknown',
        'car_connected': carConnected,
        'seek_offset_s': seekOffset.inSeconds,
      };
}
