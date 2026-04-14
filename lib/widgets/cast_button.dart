import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool get _visible => _devices.isNotEmpty || Platform.isIOS;

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
              children: [_icon(context), const SizedBox(width: 8)],
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
              _airPlayActive
                  ? Icons.airplay_rounded
                  : _chromecastCasting
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
  bool _airPlayActive = false;
  String? _airPlayDevice;
  bool _searching = true;

  @override
  void initState() {
    super.initState();

    // Listen to live device/state streams so the sheet updates in real-time
    final cs = widget.castService;
    if (cs != null) {
      _devices = cs.devices.value;
      _chromecastCasting = cs.isCasting.value;
      _subs.add(cs.devices.listen((d) {
        if (mounted) setState(() => _devices = d);
      }));
      _subs.add(cs.isCasting.listen((v) {
        if (mounted) setState(() => _chromecastCasting = v);
      }));
    }

    if (Platform.isIOS) {
      final ap = AirPlayRouteState.instance;
      _airPlayActive = ap.isActive;
      _airPlayDevice = ap.routeName;
      _subs.add(ap.isActiveStream.listen((v) {
        if (mounted) setState(() => _airPlayActive = v);
      }));
      _subs.add(ap.routeNameStream.listen((v) {
        if (mounted) setState(() => _airPlayDevice = v);
      }));
    }

    // Show searching indicator for a few seconds
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _searching = false);
    });
  }

  @override
  void dispose() {
    for (final s in _subs) { s.cancel(); }
    super.dispose();
  }

  bool get _hasConnected => _chromecastCasting || _airPlayActive;

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
              child: Text(
                'Selectează un dispozitiv',
                style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: onSurface),
              ),
            ),

            // ════════════════════════════════════════
            // CONNECTED section
            // ════════════════════════════════════════
            if (_hasConnected) ...[
              _sectionLabel(context, 'CONECTAT'),

              if (_chromecastCasting)
                _ConnectedChromecastRow(
                  onDisconnect: () {
                    widget.castService?.disconnect();
                    Navigator.of(context).pop();
                  },
                ),

              if (_airPlayActive)
                _ConnectedAirPlayRow(deviceName: _airPlayDevice),
            ],

            // ════════════════════════════════════════
            // AVAILABLE section
            // ════════════════════════════════════════
            if (!_chromecastCasting && _devices.isNotEmpty || Platform.isIOS) ...[
              if (_hasConnected) _sectionLabel(context, 'ALTE DISPOZITIVE'),

              // Chromecast devices
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

              // AirPlay (when not active)
              if (Platform.isIOS && !_airPlayActive)
                _AirPlayRow(),
            ],

            // ── Searching indicator ──
            if (_searching && _devices.isEmpty && !_hasConnected)
              _SearchingRow(),

            if (_searching && _devices.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: dim),
                    ),
                    const SizedBox(width: 10),
                    Text('Se caută alte dispozitive...',
                      style: TextStyle(fontSize: 13, color: dim)),
                  ],
                ),
              ),

            const Divider(height: 24),

            // ════════════════════════════════════════
            // EXTRA OPTIONS
            // ════════════════════════════════════════
            _DeviceRow(
              icon: Icons.tv_rounded,
              title: 'Android TV și Apple TV',
              subtitle: 'Instalează aplicația pe TV',
              onTap: () => _showTvInstructions(context),
            ),

            _DeviceRow(
              icon: Icons.link_rounded,
              title: 'Conectare cu cod TV',
              subtitle: 'Introdu codul afișat pe televizor',
              onTap: () => _showLinkByCode(context),
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
    Navigator.of(context).pop();
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _TvInstructionsSheet(),
    );
  }

  void _showLinkByCode(BuildContext context) {
    Navigator.of(context).pop();
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _LinkByCodeSheet(),
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
  final VoidCallback onDisconnect;
  const _ConnectedChromecastRow({required this.onDisconnect});

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
                  Text('Chromecast',
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

/// Connected AirPlay — highlighted with native route picker to change/disconnect.
class _ConnectedAirPlayRow extends StatelessWidget {
  final String? deviceName;
  const _ConnectedAirPlayRow({this.deviceName});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.blue.withValues(alpha: 0.2), width: 1),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.airplay_rounded, size: 24, color: Colors.blue),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(deviceName ?? 'AirPlay',
                        style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface)),
                      const Text('Conectat — atinge pentru a schimba',
                        style: TextStyle(fontSize: 13, color: Colors.blue)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    size: 20, color: Colors.blue),
              ],
            ),
          ),
          // Invisible native picker — tap anywhere on the card
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
      ),
    );
  }
}

/// AirPlay row (not connected) — native picker overlay.
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
              Navigator.of(context).pop();
              AnalyticsService.instance.capture('airplay_picker_opened');
            },
          ),
        ),
      ],
    );
  }
}

/// Searching indicator when no devices found yet.
class _SearchingRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: dim),
          ),
          const SizedBox(width: 12),
          Text('Se caută dispozitive în rețea...',
            style: TextStyle(fontSize: 14, color: dim)),
        ],
      ),
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
      child: Padding(
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
            Text('Ascultă pe televizor',
              style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700, color: onSurface)),
            const SizedBox(height: 8),
            Text(
              'Instalează aplicația Radio Creștin direct pe televizor pentru cea mai bună experiență.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: dim, height: 1.5)),
            const SizedBox(height: 24),

            // Android TV
            _InstructionCard(
              icon: Icons.android_rounded,
              iconColor: Colors.green,
              title: 'Android TV',
              steps: const [
                'Deschide Google Play Store pe TV',
                'Caută „Radio Creștin"',
                'Apasă Instalare',
                'Lansează aplicația de pe ecranul principal',
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
                'Apasă Obține',
                'Lansează aplicația de pe ecranul principal',
              ],
            ),
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

// ═══════════════════════════════════════════════════════════════════
// Link by TV code sheet
// ═══════════════════════════════════════════════════════════════════

class _LinkByCodeSheet extends StatefulWidget {
  const _LinkByCodeSheet();

  @override
  State<_LinkByCodeSheet> createState() => _LinkByCodeSheetState();
}

class _LinkByCodeSheetState extends State<_LinkByCodeSheet> {
  final _controller = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _controller.text.trim().toUpperCase();
    if (code.length < 4) return;
    setState(() => _loading = true);
    // TV code linking is a placeholder — the TV app would display a code,
    // and this screen lets the user enter it to pair. Implementation depends
    // on backend pairing API.
    AnalyticsService.instance.capture('tv_code_entered', {'code': code});
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Funcția va fi disponibilă în curând.'),
            duration: Duration(seconds: 2),
          ),
        );
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final dim = onSurface.withValues(alpha: 0.6);
    final dark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            24, 12, 24, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: dark ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2)),
            ),
            const Icon(Icons.link_rounded, size: 40, color: AppColors.primary),
            const SizedBox(height: 16),
            Text('Conectare cu cod TV',
              style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700, color: onSurface)),
            const SizedBox(height: 8),
            Text(
              'Introdu codul afișat pe ecranul televizorului pentru a conecta telefonul.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: dim, height: 1.5)),
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              textCapitalization: TextCapitalization.characters,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 28, fontWeight: FontWeight.w700,
                letterSpacing: 8, color: onSurface),
              maxLength: 6,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
              ],
              decoration: InputDecoration(
                counterText: '',
                hintText: '• • • • • •',
                hintStyle: TextStyle(
                  fontSize: 28, letterSpacing: 8,
                  color: onSurface.withValues(alpha: 0.2)),
                filled: true,
                fillColor: dark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.04),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(
                    vertical: 16, horizontal: 20),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                    : const Text('Conectare',
                        style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
