import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_airplay/flutter_airplay.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:get_it/get_it.dart';

import '../services/cast_service.dart';
import '../services/analytics_service.dart';
import '../theme.dart';

/// Animated cast button that auto-hides when no devices are available.
/// Shows a device picker dialog on tap, or disconnects if already casting.
class CastButton extends StatefulWidget {
  const CastButton({super.key});

  @override
  State<CastButton> createState() => _CastButtonState();
}

class _CastButtonState extends State<CastButton>
    with SingleTickerProviderStateMixin {
  CastService? _castService;
  final List<StreamSubscription> _subscriptions = [];

  List<GoogleCastDevice> _devices = [];
  bool _isChromecastCasting = false;
  bool _isAirPlayActive = false;
  String? _airPlayDeviceName;
  bool _initialized = false;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  bool get _isCasting => _isChromecastCasting || _isAirPlayActive;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // AirPlay route state (iOS only, no-op on Android)
    if (Platform.isIOS) {
      final airplay = AirPlayRouteState.instance;
      _isAirPlayActive = airplay.isActive;
      _airPlayDeviceName = airplay.routeName;
      _subscriptions.add(airplay.isActiveStream.listen((active) {
        if (mounted) {
          setState(() => _isAirPlayActive = active);
          _updatePulse();
        }
      }));
      _subscriptions.add(airplay.routeNameStream.listen((name) {
        if (mounted) setState(() => _airPlayDeviceName = name);
      }));
    }

    _tryInit();
    // CastService is registered lazily after first frame — retry shortly
    if (!_initialized) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _tryInit();
      });
    }
  }

  void _tryInit() {
    if (_initialized) return;
    if (!GetIt.instance.isRegistered<CastService>()) return;
    _initialized = true;
    _castService = GetIt.instance<CastService>();

    _subscriptions.add(_castService!.devices.listen((d) {
      if (mounted) setState(() => _devices = d);
    }));
    _subscriptions.add(_castService!.isCasting.listen((casting) {
      if (mounted) {
        setState(() => _isChromecastCasting = casting);
        _updatePulse();
      }
    }));
  }

  void _updatePulse() {
    if (_isCasting) {
      _pulseController.repeat(reverse: true);
    } else {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _pulseController.dispose();
    super.dispose();
  }

  bool get _hasDevices => _devices.isNotEmpty || Platform.isIOS;

  void _onTap() {
    if (_isCasting) {
      _showConnectedDialog();
    } else if (_hasDevices) {
      _showDevicePicker();
    }
  }

  void _showDevicePicker() {
    if (_castService == null) return;
    AnalyticsService.instance
        .capture('cast_picker_opened', {'device_count': _devices.length});
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha:0.65),
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: _CastDevicePickerDialog(
          devices: _devices,
          castService: _castService!,
        ),
      ),
    );
  }

  void _showConnectedDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha:0.65),
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: _CastConnectedDialog(
          castService: _castService,
          isAirPlay: _isAirPlayActive,
          deviceName: _isAirPlayActive ? _airPlayDeviceName : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Hide completely when no devices found
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(
          sizeFactor: animation,
          axis: Axis.horizontal,
          child: child,
        ),
      ),
      child: !_hasDevices
          ? const SizedBox.shrink(key: ValueKey('empty'))
          : Row(
              key: const ValueKey('cast'),
              mainAxisSize: MainAxisSize.min,
              children: [
                ScaleTransition(
                  scale: _isCasting ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
                  child: _buildButton(context),
                ),
                const SizedBox(width: 8),
              ],
            ),
    );
  }

  Widget _buildButton(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: _isCasting
          ? AppColors.primary.withValues(alpha: 0.15)
          : isDark
              ? Colors.white.withValues(alpha: 0.07)
              : Colors.black.withValues(alpha: 0.06),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: _onTap,
        customBorder: const CircleBorder(),
        child: Tooltip(
          message: _isCasting ? 'Oprește transmiterea' : 'Transmite pe dispozitiv',
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              _isAirPlayActive
                  ? Icons.airplay_rounded
                  : _isChromecastCasting
                      ? Icons.cast_connected_rounded
                      : Icons.cast_rounded,
              size: 22,
              color: _isCasting
                  ? AppColors.primary
                  : isDark
                      ? Colors.white70
                      : Colors.grey.shade700,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Device picker dialog
// ---------------------------------------------------------------------------

class _CastDevicePickerDialog extends StatelessWidget {
  final List<GoogleCastDevice> devices;
  final CastService castService;

  const _CastDevicePickerDialog({
    required this.devices,
    required this.castService,
  });

  static String _deviceCountLabel(int chromecastCount) {
    final total = chromecastCount + (Platform.isIOS ? 1 : 0); // +1 for AirPlay
    if (total == 1) return '1 opțiune disponibilă';
    return '$total opțiuni disponibile';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha:0.3),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha:0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.cast_rounded,
                      color: AppColors.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Transmite pe',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          _deviceCountLabel(devices.length),
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha:0.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha:0.5),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Chromecast device list
            if (devices.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    final device = devices[index];
                    return _DeviceTile(
                      device: device,
                      onTap: () async {
                        Navigator.of(context).pop();
                        await castService.connectToDevice(device);
                      },
                    );
                  },
                ),
              ),
            // AirPlay section (iOS only)
            if (Platform.isIOS) ...[
              if (devices.isNotEmpty) const Divider(height: 1),
              _AirPlayTile(),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final GoogleCastDevice device;
  final VoidCallback onTap;

  const _DeviceTile({required this.device, required this.onTap});

  IconData _deviceIcon() {
    final name = device.friendlyName.toLowerCase();
    if (name.contains('tv') || name.contains('television')) {
      return Icons.tv_rounded;
    }
    if (name.contains('speaker') || name.contains('home') || name.contains('nest')) {
      return Icons.speaker_rounded;
    }
    if (name.contains('display') || name.contains('hub')) {
      return Icons.tablet_rounded;
    }
    return Icons.cast_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha:0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _deviceIcon(),
                  size: 22,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.friendlyName,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    if (device.modelName != null && device.modelName!.isNotEmpty)
                      Text(
                        device.modelName!,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha:0.5),
                        ),
                      ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha:0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AirPlay tile — embeds native AVRoutePickerView inside the dialog
// ---------------------------------------------------------------------------

class _AirPlayTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.airplay_rounded,
              size: 22,
              color: Colors.blue,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AirPlay',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                Text(
                  'AirPods, HomePod, Apple TV, difuzoare',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          // Native AirPlay route picker button — triggers iOS system picker
          SizedBox(
            width: 44,
            height: 44,
            child: AirPlayRoutePickerView(
              tintColor: Theme.of(context).colorScheme.primary,
              activeTintColor: Colors.blue,
              onShowPickerView: () {
                Navigator.of(context).pop();
                AnalyticsService.instance.capture('airplay_picker_opened');
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Connected / disconnect dialog
// ---------------------------------------------------------------------------

class _CastConnectedDialog extends StatelessWidget {
  final CastService? castService;
  final bool isAirPlay;
  final String? deviceName;

  const _CastConnectedDialog({
    required this.castService,
    this.isAirPlay = false,
    this.deviceName,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final icon = isAirPlay ? Icons.airplay_rounded : Icons.cast_connected_rounded;
    final label = isAirPlay ? 'AirPlay' : 'Chromecast';
    final subtitle = deviceName != null
        ? 'Se redă pe $deviceName'
        : 'Radioul se redă pe dispozitivul conectat.';

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha:0.3),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: (isAirPlay ? Colors.blue : AppColors.primary).withValues(alpha:0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  icon,
                  color: isAirPlay ? Colors.blue : AppColors.primary,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Se transmite prin $label',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha:0.6),
                ),
              ),
              const SizedBox(height: 24),
              if (isAirPlay)
                // AirPlay: show native route picker to switch/disconnect
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: Stack(
                    children: [
                      // Visual button
                      Container(
                        width: double.infinity,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.airplay_rounded, size: 20, color: Colors.white),
                            SizedBox(width: 8),
                            Text(
                              'Schimbă dispozitivul',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Invisible native picker overlaid on top
                      Positioned.fill(
                        child: AirPlayRoutePickerView(
                          tintColor: Colors.transparent,
                          activeTintColor: Colors.transparent,
                          backgroundColor: Colors.transparent,
                          onShowPickerView: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ],
                  ),
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      castService?.disconnect();
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.cast_rounded, size: 20),
                    label: const Text('Oprește transmiterea'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
