import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_airplay/flutter_airplay.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:get_it/get_it.dart';

import '../services/cast_service.dart';
import '../services/analytics_service.dart';
import '../theme.dart';

/// Cast button in the AppBar — auto-appears when devices are found.
/// Single tap opens a unified bottom sheet with all available devices.
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
    if (!_hasDevices) return;
    AnalyticsService.instance
        .capture('cast_picker_opened', {'device_count': _devices.length});
    _showDeviceSheet();
  }

  void _showDeviceSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _DeviceSheet(
        devices: _devices,
        castService: _castService,
        isChromecastCasting: _isChromecastCasting,
        isAirPlayActive: _isAirPlayActive,
        airPlayDeviceName: _airPlayDeviceName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  scale: _isCasting
                      ? _pulseAnimation
                      : const AlwaysStoppedAnimation(1.0),
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
          message:
              _isCasting ? 'Oprește transmiterea' : 'Transmite pe dispozitiv',
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
// Unified device bottom sheet (YouTube-style)
// ---------------------------------------------------------------------------

class _DeviceSheet extends StatelessWidget {
  final List<GoogleCastDevice> devices;
  final CastService? castService;
  final bool isChromecastCasting;
  final bool isAirPlayActive;
  final String? airPlayDeviceName;

  const _DeviceSheet({
    required this.devices,
    required this.castService,
    required this.isChromecastCasting,
    required this.isAirPlayActive,
    required this.airPlayDeviceName,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 16),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white24
                    : Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Selectează un dispozitiv',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // --- Connected device (if casting) ---
          if (isChromecastCasting)
            _SheetRow(
              icon: Icons.cast_connected_rounded,
              iconColor: AppColors.primary,
              title: 'Conectat la Chromecast',
              trailing: TextButton(
                onPressed: () {
                  castService?.disconnect();
                  Navigator.of(context).pop();
                },
                child: const Text('Deconectare'),
              ),
            ),

          if (isAirPlayActive)
            _AirPlaySheetRow(
              deviceName: airPlayDeviceName,
              isActive: true,
            ),

          // --- Available Chromecast devices ---
          if (!isChromecastCasting)
            ...devices.map((device) => _ChromecastDeviceRow(
                  device: device,
                  onTap: () async {
                    Navigator.of(context).pop();
                    await castService?.connectToDevice(device);
                  },
                )),

          // --- AirPlay row (iOS only, when not already active) ---
          if (Platform.isIOS && !isAirPlayActive)
            _AirPlaySheetRow(isActive: false),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// --- Chromecast device row ---

class _ChromecastDeviceRow extends StatelessWidget {
  final GoogleCastDevice device;
  final VoidCallback onTap;

  const _ChromecastDeviceRow({required this.device, required this.onTap});

  IconData _deviceIcon() {
    final name = device.friendlyName.toLowerCase();
    if (name.contains('tv') || name.contains('television')) {
      return Icons.tv_rounded;
    }
    if (name.contains('speaker') ||
        name.contains('home') ||
        name.contains('nest')) {
      return Icons.speaker_rounded;
    }
    if (name.contains('display') || name.contains('hub')) {
      return Icons.tablet_rounded;
    }
    return Icons.cast_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return _SheetRow(
      icon: _deviceIcon(),
      title: device.friendlyName,
      subtitle: device.modelName,
      onTap: onTap,
    );
  }
}

// --- AirPlay row with native picker overlay ---

class _AirPlaySheetRow extends StatelessWidget {
  final String? deviceName;
  final bool isActive;

  const _AirPlaySheetRow({this.deviceName, required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _SheetRow(
          icon: Icons.airplay_rounded,
          iconColor: isActive ? Colors.blue : null,
          title: isActive
              ? (deviceName != null ? 'AirPlay: $deviceName' : 'AirPlay conectat')
              : 'AirPlay și Bluetooth',
          subtitle: isActive ? null : 'AirPods, HomePod, Apple TV, difuzoare',
          trailing: isActive
              ? Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle,
                  ),
                )
              : null,
        ),
        // Invisible native picker covers the entire row — any tap triggers iOS system sheet
        Positioned.fill(
          child: AirPlayRoutePickerView(
            tintColor: Colors.transparent,
            activeTintColor: Colors.transparent,
            backgroundColor: Colors.transparent,
            onShowPickerView: () {
              Navigator.of(context).pop();
              AnalyticsService.instance.capture('airplay_picker_opened');
            },
          ),
        ),
      ],
    );
  }
}

// --- Generic sheet row ---

class _SheetRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  const _SheetRow({
    required this.icon,
    this.iconColor,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final color = iconColor ??
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.5),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
