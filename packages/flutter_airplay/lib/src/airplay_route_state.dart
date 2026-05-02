import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Monitors AirPlay route state via native AVAudioSession and AVRouteDetector.
///
/// Provides reactive streams for:
/// - [isAirPlayActive] — whether audio is currently routing through AirPlay
/// - [isAirPlayAvailable] — whether AirPlay devices are detected on the network
/// - [routeName] — the name of the connected AirPlay device (e.g. "Living Room")
class AirPlayRouteState {
  static const _channel = MethodChannel('flutter_airplay/route_state');
  static AirPlayRouteState? _instance;

  final _isActiveController = StreamController<bool>.broadcast();
  final _isAvailableController = StreamController<bool>.broadcast();
  final _routeNameController = StreamController<String?>.broadcast();

  bool _isActive = false;
  bool _isAvailable = false;
  String? _routeName;

  AirPlayRouteState._() {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _channel.setMethodCallHandler(_handleNativeCall);
      // Query initial state
      _queryInitialState();
    }
  }

  /// Singleton instance.
  static AirPlayRouteState get instance {
    _instance ??= AirPlayRouteState._();
    return _instance!;
  }

  /// Whether audio is currently routed through AirPlay.
  bool get isActive => _isActive;
  Stream<bool> get isActiveStream => _isActiveController.stream;

  /// Whether AirPlay-capable devices are detected on the local network.
  bool get isAvailable => _isAvailable;
  Stream<bool> get isAvailableStream => _isAvailableController.stream;

  /// Name of the connected AirPlay device, or null if not connected.
  String? get routeName => _routeName;
  Stream<String?> get routeNameStream => _routeNameController.stream;

  Future<void> _queryInitialState() async {
    try {
      _isActive = await _channel.invokeMethod<bool>('isAirPlayActive') ?? false;
      _isAvailable = await _channel.invokeMethod<bool>('isAirPlayAvailable') ?? false;
      _routeName = await _channel.invokeMethod<String?>('getCurrentRouteName');
      _isActiveController.add(_isActive);
      _isAvailableController.add(_isAvailable);
      _routeNameController.add(_routeName);
    } catch (e) {
      developer.log('AirPlayRouteState: initial query failed: $e');
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onRouteStateChanged') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final active = args['isAirPlayActive'] as bool? ?? false;
      final available = args['isAirPlayAvailable'] as bool? ?? false;
      final name = args['routeName'] as String?;
      final nameOrNull = (name != null && name.isNotEmpty) ? name : null;

      if (active != _isActive) {
        _isActive = active;
        _isActiveController.add(active);
        developer.log('AirPlayRouteState: active=$active device=$nameOrNull');
      }
      if (available != _isAvailable) {
        _isAvailable = available;
        _isAvailableController.add(available);
      }
      if (nameOrNull != _routeName) {
        _routeName = nameOrNull;
        _routeNameController.add(nameOrNull);
      }
    }
  }

  void dispose() {
    _isActiveController.close();
    _isAvailableController.close();
    _routeNameController.close();
    _instance = null;
  }
}
