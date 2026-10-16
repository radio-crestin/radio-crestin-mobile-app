import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/services/log_context.dart';
import 'package:radio_crestin/services/network_service.dart';

void main() {
  group('LogContext.build', () {
    test('describes a phone on mobile data in the background, in the car', () {
      final context = LogContext.build(
        status: ConnectionStatus.online,
        onMobileData: true,
        appState: AppLifecycleState.paused,
        carConnected: true,
        seekOffset: const Duration(minutes: 5),
      );

      expect(context, {
        'network': 'online',
        'on_mobile_data': true,
        'app_state': 'paused',
        'car_connected': true,
        'seek_offset_s': 300,
      });
    });

    test('names each connection status', () {
      String network(ConnectionStatus status) => LogContext.build(
            status: status,
            onMobileData: false,
            appState: AppLifecycleState.resumed,
            carConnected: false,
            seekOffset: Duration.zero,
          )['network'] as String;

      expect(network(ConnectionStatus.online), 'online');
      expect(network(ConnectionStatus.offline), 'offline');
      expect(network(ConnectionStatus.noInternet), 'no_internet');
    });

    test('an app state not known yet reads as unknown', () {
      final context = LogContext.build(
        status: ConnectionStatus.online,
        onMobileData: false,
        appState: null,
        carConnected: false,
        seekOffset: const Duration(minutes: 2),
      );

      expect(context['app_state'], 'unknown');
      expect(context['seek_offset_s'], 120);
    });
  });
}
