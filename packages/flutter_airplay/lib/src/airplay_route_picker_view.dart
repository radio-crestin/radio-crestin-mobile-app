import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native iOS AirPlay route picker (wraps AVRoutePickerView).
///
/// Shows available audio output routes: AirPlay speakers, Bluetooth devices,
/// HomePods, Apple TV, etc. Selecting a route redirects all audio output.
///
/// On non-iOS platforms, renders an empty SizedBox.
class AirPlayRoutePickerView extends StatefulWidget {
  const AirPlayRoutePickerView({
    super.key,
    this.tintColor,
    this.activeTintColor,
    this.backgroundColor,
    this.height = 44.0,
    this.width = 44.0,
    this.onShowPickerView,
    this.onClosePickerView,
  });

  final Color? tintColor;
  final Color? activeTintColor;
  final Color? backgroundColor;
  final double height;
  final double width;
  final VoidCallback? onShowPickerView;
  final VoidCallback? onClosePickerView;

  Map<String, dynamic> _createParams() {
    return <String, dynamic>{
      'class': 'AirplayRoutePicker',
      // Audio-focused: video devices are not prioritized
      'prioritizesVideoDevices': false,
      if (tintColor != null) 'tintColor': _colorToParams(tintColor!),
      if (activeTintColor != null) 'activeTintColor': _colorToParams(activeTintColor!),
      if (backgroundColor != null) 'backgroundColor': _colorToParams(backgroundColor!),
    };
  }

  static Map<String, dynamic> _colorToParams(Color color) {
    return {
      'red': color.r,
      'green': color.g,
      'blue': color.b,
      'alpha': color.a,
    };
  }

  @override
  State<AirPlayRoutePickerView> createState() => _AirPlayRoutePickerViewState();
}

class _AirPlayRoutePickerViewState extends State<AirPlayRoutePickerView> {
  static const _channelPrefix = 'flutter_airplay';
  MethodChannel? _methodChannel;

  @override
  void dispose() {
    _disposeChannel();
    super.dispose();
  }

  void _onPlatformViewCreated(int id) {
    final name = '$_channelPrefix#$id';
    if (_methodChannel?.name != name) {
      _disposeChannel();
    }
    _methodChannel = MethodChannel(name);
    _methodChannel!.setMethodCallHandler(_onPlatformCall);
  }

  Future<dynamic> _onPlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'onShowPickerView':
        widget.onShowPickerView?.call();
      case 'onClosePickerView':
        widget.onClosePickerView?.call();
    }
  }

  void _disposeChannel() {
    _methodChannel?.setMethodCallHandler(null);
    _methodChannel = null;
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return SizedBox(width: widget.width, height: widget.height);
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: UiKitView(
        viewType: 'airplay_route_picker_view',
        creationParamsCodec: const StandardMessageCodec(),
        creationParams: widget._createParams(),
        onPlatformViewCreated: _onPlatformViewCreated,
      ),
    );
  }
}
