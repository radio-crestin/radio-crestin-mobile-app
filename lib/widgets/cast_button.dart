import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_airplay/flutter_airplay.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:get_it/get_it.dart';

import '../services/cast_service.dart';
import '../services/analytics_service.dart';
import '../theme.dart';

// ═══════════════════════════════════════════════════════════════════
// Cast AppBar button
// ═══════════════════════════════════════════════════════════════════

class CastButton extends StatefulWidget {
  const CastButton({super.key});

  @override
  State<CastButton> createState() => _CastButtonState();
}

class _CastButtonState extends State<CastButton> {
  CastService? _castService;
  final List<StreamSubscription> _subs = [];

  List<GoogleCastDevice> _devices = [];
  bool _chromecastCasting = false;
  bool _airPlayActive = false;
  bool _ready = false;

  bool get _casting => _chromecastCasting || _airPlayActive;
  bool get _visible => _devices.isNotEmpty || Platform.isIOS || _chromecastCasting;

  @override
  void initState() {
    super.initState();
    if (Platform.isIOS) {
      final ap = AirPlayRouteState.instance;
      _airPlayActive = ap.isActive;
      _subs.add(ap.isActiveStream.listen((v) {
        if (mounted) setState(() => _airPlayActive = v);
      }));
    }
    _tryInit();
    if (!_ready) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _tryInit();
      });
    }
  }

  void _tryInit() {
    if (_ready || !GetIt.instance.isRegistered<CastService>()) return;
    _ready = true;
    _castService = GetIt.instance<CastService>();
    _subs.add(_castService!.devices.listen((d) {
      if (mounted) setState(() => _devices = d);
    }));
    _subs.add(_castService!.isCasting.listen((v) {
      if (mounted) setState(() => _chromecastCasting = v);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) { s.cancel(); }
    super.dispose();
  }

  void _open() {
    if (!_visible) return;
    AnalyticsService.instance.capture('cast_picker_opened', {
      'device_count': _devices.length,
    });
    // Re-arm discovery on each tap. On iOS this re-issues the Bonjour
    // browse request, which (re)triggers the Local Network permission
    // prompt the very first time and is otherwise a cheap no-op. Lets
    // a user who initially denied the prompt recover by tapping again
    // (after toggling iOS Settings → Radio Creștin → Local Network ON).
    _castService?.restartDiscovery();
    showModalBottomSheet(
      context: context,
      backgroundColor:
          Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1E1E1E)
              : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (_) => _DeviceSheet(castService: _castService),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SizeTransition(
          sizeFactor: anim, axis: Axis.horizontal, child: child),
      ),
      child: !_visible
          ? const SizedBox.shrink(key: ValueKey('no'))
          : Row(
              key: const ValueKey('yes'),
              mainAxisSize: MainAxisSize.min,
              children: [
                // AirPlay active → button IS the native picker (tap = iOS system sheet)
                if (_airPlayActive)
                  _airPlayButton(context)
                else
                  _icon(context),
                const SizedBox(width: 8),
              ],
            ),
    );
  }

  /// When AirPlay is active, the button itself is the native route picker.
  Widget _airPlayButton(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        children: [
          // Visual button
          Material(
            color: AppColors.primary.withValues(alpha: 0.15),
            shape: const CircleBorder(),
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.airplay_rounded, size: 22,
                  color: AppColors.primary),
            ),
          ),
          // Native picker overlay — tap opens iOS system route sheet
          Positioned.fill(
            child: AirPlayRoutePickerView(
              tintColor: Colors.transparent,
              activeTintColor: Colors.transparent,
              backgroundColor: Colors.transparent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _icon(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: _casting
          ? AppColors.primary.withValues(alpha: 0.15)
          : dark
              ? Colors.white.withValues(alpha: 0.07)
              : Colors.black.withValues(alpha: 0.06),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: _open,
        customBorder: const CircleBorder(),
        child: Tooltip(
          message: _casting ? 'Dispozitiv conectat' : 'Transmite pe dispozitiv',
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              _chromecastCasting
                  ? Icons.cast_connected_rounded
                  : Icons.cast_rounded,
              size: 22,
              color: _casting
                  ? AppColors.primary
                  : dark ? Colors.white70 : Colors.grey.shade700,
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Device bottom sheet — live-updating, unified
// ═══════════════════════════════════════════════════════════════════

class _DeviceSheet extends StatefulWidget {
  final CastService? castService;
  const _DeviceSheet({required this.castService});

  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> {
  final List<StreamSubscription> _subs = [];

  List<GoogleCastDevice> _devices = [];
  bool _chromecastCasting = false;
  String? _connectedDeviceName;
  bool _searching = true;

  @override
  void initState() {
    super.initState();

    // Listen to live device/state streams so the sheet updates in real-time
    final cs = widget.castService;
    if (cs != null) {
      _devices = cs.devices.value;
      _chromecastCasting = cs.isCasting.value;
      _connectedDeviceName = cs.connectedDeviceName.value;

      // Discovery runs continuously from app init — the sheet just
      // reflects the live device list. Do NOT restart here: on a cold
      // launch the first mDNS announcements usually omit the
      // `_CC1AD845` subtype, so the SDK must TCP-probe each device
      // (~20s). Restarting the scan on every open cancels those
      // in-flight probes and forces the whole cycle to start over,
      // which makes the sheet look empty when devices were seconds
      // away from publishing. Manual refresh is available via the
      // "Caută din nou" button below.

      _subs.add(cs.devices.listen((d) {
        if (mounted) setState(() => _devices = d);
      }));
      _subs.add(cs.isCasting.listen((v) {
        if (mounted) setState(() => _chromecastCasting = v);
      }));
      _subs.add(cs.connectedDeviceName.listen((name) {
        if (mounted) setState(() => _connectedDeviceName = name);
      }));
    }

    _startSearchTimer();
  }

  void _startSearchTimer() {
    // Show searching indicator while scanning (mDNS can take up to 15s)
    Future.delayed(const Duration(seconds: 15), () {
      if (mounted) setState(() => _searching = false);
    });
  }

  void _rescan() {
    widget.castService?.restartDiscovery();
    setState(() => _searching = true);
    _startSearchTimer();
  }

  @override
  void dispose() {
    for (final s in _subs) { s.cancel(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final dim = onSurface.withValues(alpha: 0.5);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Drag handle ──
            Center(
              child: Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 16),
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // ── Header ──
            Padding(
              padding: const EdgeInsets.only(left: 20, right: 20, bottom: 4),
              child: Row(
                children: [
                  Text(
                    'Selectează un dispozitiv',
                    style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600,
                      color: onSurface),
                  ),
                  if (_searching) ...[
                    const Spacer(),
                    SizedBox(
                      width: 12, height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: dim),
                    ),
                    const SizedBox(width: 6),
                    Text('Se caută dispozitive...', style: TextStyle(
                      fontSize: 12, color: dim)),
                  ],
                ],
              ),
            ),

            // Connected Chromecast
            if (_chromecastCasting) ...[
              _sectionLabel(context, 'CONECTAT'),
              _ConnectedChromecastRow(
                deviceName: _connectedDeviceName,
                onDisconnect: () {
                  widget.castService?.disconnect();
                  Navigator.of(context).pop();
                },
              ),
              if (_devices.length > 1 || Platform.isIOS)
                _sectionLabel(context, 'ALTE DISPOZITIVE'),
            ],

            // Available Chromecast devices
            if (!_chromecastCasting)
              ..._devices.map((device) => _DeviceRow(
                icon: _chromecastIcon(device.friendlyName),
                title: device.friendlyName,
                subtitle: device.modelName,
                onTap: () async {
                  Navigator.of(context).pop();
                  await widget.castService?.connectToDevice(device);
                },
              )),

            // Scan again button — shown when not actively searching
            if (!_chromecastCasting && !_searching)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: SizedBox(
                  width: double.infinity,
                  height: 40,
                  child: OutlinedButton.icon(
                    onPressed: _rescan,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(
                      _devices.isEmpty
                          ? 'Caută din nou'
                          : 'Caută alte dispozitive',
                      style: const TextStyle(fontSize: 13),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: dim,
                      side: BorderSide(color: dim.withValues(alpha: 0.3)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ),

            // AirPlay — native picker (handles connect & disconnect)
            if (Platform.isIOS)
              _AirPlayRow(),

            // Android TV & Apple TV
            _DeviceRow(
              icon: Icons.tv_rounded,
              title: 'Android TV și Apple TV',
              subtitle: 'Instalează aplicația pe TV',
              onTap: () => _showTvInstructions(context),
            ),

            // Android Auto & Apple CarPlay
            _DeviceRow(
              icon: Icons.directions_car_rounded,
              title: 'Android Auto și Apple CarPlay',
              subtitle: 'Ascultă în mașină',
              onTap: () => _showCarInstructions(context),
            ),

          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, top: 12, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
        ),
      ),
    );
  }

  static IconData _chromecastIcon(String name) {
    final n = name.toLowerCase();
    if (n.contains('tv') || n.contains('television')) return Icons.tv_rounded;
    if (n.contains('speaker') || n.contains('home') || n.contains('nest')) {
      return Icons.speaker_rounded;
    }
    if (n.contains('display') || n.contains('hub')) return Icons.tablet_rounded;
    return Icons.cast_rounded;
  }

  void _showTvInstructions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (_) => const _TvInstructionsSheet(),
    );
  }

  void _showCarInstructions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (_) => const _CarInstructionsSheet(),
    );
  }

}

// ═══════════════════════════════════════════════════════════════════
// Row widgets
// ═══════════════════════════════════════════════════════════════════

/// Generic tappable row.
class _DeviceRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  const _DeviceRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                    style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurface)),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(subtitle!,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: 0.5))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Connected Chromecast — highlighted with disconnect button.
class _ConnectedChromecastRow extends StatelessWidget {
  final String? deviceName;
  final VoidCallback onDisconnect;
  const _ConnectedChromecastRow({
    this.deviceName,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.2), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.cast_connected_rounded,
                size: 24, color: AppColors.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(deviceName ?? 'Chromecast',
                    style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface)),
                  Text('Conectat',
                    style: TextStyle(
                      fontSize: 13, color: AppColors.primary)),
                ],
              ),
            ),
            SizedBox(
              height: 34,
              child: TextButton(
                onPressed: onDisconnect,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Deconectare',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AirPlay row with native picker overlay — always shows, handles both connect & disconnect.
class _AirPlayRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _DeviceRow(
          icon: Icons.airplay_rounded,
          title: 'AirPlay și Bluetooth',
          subtitle: 'AirPods, HomePod, Apple TV, difuzoare',
        ),
        Positioned.fill(
          child: AirPlayRoutePickerView(
            tintColor: Colors.transparent,
            activeTintColor: Colors.transparent,
            backgroundColor: Colors.transparent,
            onShowPickerView: () {
              AnalyticsService.instance.capture('airplay_picker_opened');
            },
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// TV instructions sheet
// ═══════════════════════════════════════════════════════════════════

class _TvInstructionsSheet extends StatelessWidget {
  const _TvInstructionsSheet();

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final dim = onSurface.withValues(alpha: 0.6);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2)),
            ),

            const Icon(Icons.tv_rounded, size: 48, color: AppColors.primary),
            const SizedBox(height: 16),
            Text('Ascultă Radio Creștin pe televizor',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700, color: onSurface)),
            const SizedBox(height: 8),
            Text(
              'Instalează aplicația direct pe TV pentru cea mai bună experiență.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: dim, height: 1.5)),
            const SizedBox(height: 24),

            // Android TV
            _InstructionCard(
              icon: Icons.android_rounded,
              iconColor: Colors.green,
              title: 'Android TV',
              steps: const [
                'Deschide Google Play Store pe televizor',
                'Caută „Radio Creștin"',
                'Apasă „Instalează"',
                'Deschide aplicația și alege stația preferată',
              ],
            ),
            const SizedBox(height: 12),

            // Apple TV
            _InstructionCard(
              icon: Icons.apple_rounded,
              iconColor: onSurface,
              title: 'Apple TV',
              steps: const [
                'Deschide App Store pe Apple TV',
                'Caută „Radio Creștin"',
                'Apasă „Obține" și instalează aplicația',
                'Deschide aplicația și alege stația preferată',
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Car instructions sheet
// ═══════════════════════════════════════════════════════════════════

class _CarInstructionsSheet extends StatelessWidget {
  const _CarInstructionsSheet();

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final dim = onSurface.withValues(alpha: 0.6);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2)),
            ),

            const Icon(Icons.directions_car_rounded,
                size: 48, color: AppColors.primary),
            const SizedBox(height: 16),
            Text('Ascultă Radio Creștin în mașină',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700, color: onSurface)),
            const SizedBox(height: 8),
            Text(
              'Conectează telefonul la mașină pentru a folosi aplicația pe ecranul de bord.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: dim, height: 1.5)),
            const SizedBox(height: 24),

            // Android Auto
            _InstructionCard(
              icon: Icons.android_rounded,
              iconColor: Colors.green,
              title: 'Android Auto',
              steps: const [
                'Conectează telefonul la mașină prin USB sau wireless',
                'Pornește Android Auto pe ecranul mașinii',
                'Deschide secțiunea Audio',
                'Apasă „Radio Creștin" și alege stația',
              ],
            ),
            const SizedBox(height: 12),

            // Apple CarPlay
            _InstructionCard(
              icon: Icons.apple_rounded,
              iconColor: onSurface,
              title: 'Apple CarPlay',
              steps: const [
                'Conectează iPhone-ul la mașină prin USB sau wireless',
                'Pornește CarPlay pe ecranul mașinii',
                'Apasă pictograma „Radio Creștin"',
                'Alege stația și ascultă',
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Sfat: aplicația trebuie să fie instalată pe acest telefon, iar Android Auto sau CarPlay să fie activat în setările mașinii.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: dim, height: 1.5)),
          ],
        ),
      ),
    );
  }
}

class _InstructionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final List<String> steps;

  const _InstructionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.steps,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dark ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 8),
              Text(title,
                style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface)),
            ],
          ),
          const SizedBox(height: 10),
          ...steps.asMap().entries.map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 20,
                  child: Text('${e.key + 1}.',
                    style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppColors.primary)),
                ),
                Expanded(
                  child: Text(e.value,
                    style: TextStyle(
                      fontSize: 13, height: 1.4,
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.7))),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
}

