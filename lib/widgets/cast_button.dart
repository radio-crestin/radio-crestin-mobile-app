import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_airplay/flutter_airplay.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:get_it/get_it.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/cast_service.dart';
import '../services/analytics_service.dart';
import '../services/local_network_access.dart';
import '../theme.dart';
import 'bar_icon_button.dart';

// ═══════════════════════════════════════════════════════════════════
// Device picker entry point
// ═══════════════════════════════════════════════════════════════════

/// Opens the device sheet: Chromecast, AirPlay and Bluetooth, TV and car.
///
/// [source] tags the analytics event with the screen that opened it.
void showCastDevicePicker(BuildContext context, {required String source}) {
  final castService = GetIt.instance.isRegistered<CastService>()
      ? GetIt.instance<CastService>()
      : null;
  AnalyticsService.instance.capture('cast_picker_opened', {
    'source': source,
    'device_count': castService?.devices.value.length ?? 0,
  });
  // On iOS the first open starts discovery and with it the Local Network
  // permission prompt, which stays off app launch.
  castService?.onCastButtonTapped();
  _showSheet(context, _DeviceSheet(castService: castService));
}

/// Opens [sheet] from the bottom, on the device sheet's surface.
void _showSheet(BuildContext context, Widget sheet) {
  showModalBottomSheet(
    context: context,
    // The sheet paints its own surface, which follows a theme change while
    // it's open (iOS turning dark at sunset). A color given here is picked
    // once, when the sheet opens.
    backgroundColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    builder: (_) => _SheetSurface(child: sheet),
  );
}

/// The rounded surface under a device sheet, in the current theme's color.
class _SheetSurface extends StatelessWidget {
  final Widget child;

  const _SheetSurface({required this.child});

  @override
  Widget build(BuildContext context) {
    // A Material, so the rows' ripples show on it.
    return Material(
      color: Theme.of(context).deviceSheetColors.sheet,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Active route tracking
// ═══════════════════════════════════════════════════════════════════

/// Tracks whether audio plays on a Chromecast or an AirPlay device.
mixin _CastRouteTracker<T extends StatefulWidget> on State<T> {
  final List<StreamSubscription> _routeSubs = [];

  bool _chromecastCasting = false;
  bool _airPlayActive = false;
  bool _castServiceReady = false;

  @override
  void initState() {
    super.initState();
    // Guard the AirPlay singleton access: on some app-store-signed builds the
    // flutter_airplay platform channel can throw during static `instance`
    // resolution before its iOS plugin handler is registered. An unhandled
    // throw here aborts initState, build() never runs, and the whole widget
    // renders as zero-size in release — looks exactly like "the cast button
    // disappeared on TestFlight". The cast picker still opens fine without
    // the live AirPlay state; we just lose the icon-swap when AirPlay is
    // routing.
    if (Platform.isIOS) {
      try {
        final ap = AirPlayRouteState.instance;
        _airPlayActive = ap.isActive;
        _routeSubs.add(ap.isActiveStream.listen((v) {
          if (mounted) setState(() => _airPlayActive = v);
        }));
      } catch (e, st) {
        debugPrint('$runtimeType: AirPlayRouteState init failed: $e\n$st');
      }
    }
    _watchCastService();
    // CastService registers after the first frame.
    if (!_castServiceReady) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _watchCastService();
      });
    }
  }

  void _watchCastService() {
    if (_castServiceReady || !GetIt.instance.isRegistered<CastService>()) {
      return;
    }
    _castServiceReady = true;
    _routeSubs.add(GetIt.instance<CastService>().isCasting.listen((v) {
      if (mounted) setState(() => _chromecastCasting = v);
    }));
  }

  @override
  void dispose() {
    for (final s in _routeSubs) { s.cancel(); }
    super.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════════
// Full player cast button
// ═══════════════════════════════════════════════════════════════════

/// Cast button in the full player header, always visible.
///
/// The icon and its color follow the active route (Chromecast, AirPlay or
/// this phone), so the user sees where the audio plays before tapping.
class PlayerCastButton extends StatefulWidget {
  /// Side length of the square tap target, roomier than the 48 minimum
  /// since the header's buttons sit close to the screen edge.
  static const double size = 56;

  final VoidCallback onPressed;

  const PlayerCastButton({super.key, required this.onPressed});

  @override
  State<PlayerCastButton> createState() => _PlayerCastButtonState();
}

class _PlayerCastButtonState extends State<PlayerCastButton>
    with _CastRouteTracker<PlayerCastButton> {
  @override
  Widget build(BuildContext context) {
    final connected = _chromecastCasting || _airPlayActive;
    final icon = _airPlayActive
        ? Icons.airplay_rounded
        : _chromecastCasting
            ? Icons.cast_connected_rounded
            : Icons.cast_rounded;
    // The lighter/deeper brand pinks keep a clear contrast on the panel.
    final color = !connected
        ? Theme.of(context).colorScheme.onSurface
        : Theme.of(context).brightness == Brightness.dark
            ? AppColors.sleepAccent
            : AppColors.sleepAccentOnLight;
    return SizedBox.square(
      dimension: PlayerCastButton.size,
      child: IconButton(
        onPressed: widget.onPressed,
        tooltip: connected
            ? 'Dispozitiv conectat'
            : 'Transmite pe alt dispozitiv',
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: Icon(icon, key: ValueKey(icon), size: 22, color: color),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Cast AppBar button
// ═══════════════════════════════════════════════════════════════════

/// App bar indicator, shown only while audio plays on another device.
///
/// Starting a cast lives in the full player (see [PlayerCastButton]). The
/// app bar only surfaces an active Chromecast or AirPlay route, so the user
/// sees where the audio goes and can stop it in one tap.
class CastButton extends StatefulWidget {
  const CastButton({super.key, required this.height});

  /// The height of the app bar, all of which takes the button's touches.
  final double height;

  @override
  State<CastButton> createState() => _CastButtonState();
}

class _CastButtonState extends State<CastButton>
    with _CastRouteTracker<CastButton> {
  bool get _visible => _chromecastCasting || _airPlayActive;

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.log('cast button init', {
      'platform': Platform.isIOS ? 'ios' : Platform.isAndroid ? 'android' : 'other',
      'visible_initial': _visible,
      'airplay_active': _airPlayActive,
      'cast_service_ready': _castServiceReady,
    });
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
          // AirPlay active → button IS the native picker (tap = iOS system sheet)
          : _airPlayActive
              ? _airPlayButton(key: const ValueKey('airplay'))
              : _chromecastButton(key: const ValueKey('chromecast')),
    );
  }

  /// When AirPlay is active, the button itself is the native route picker.
  Widget _airPlayButton({required Key key}) {
    return SizedBox(
      key: key,
      width: BarIconButton.width,
      height: widget.height,
      child: Stack(
        children: [
          const Center(
            child: Icon(Icons.airplay_rounded,
                size: 22, color: AppColors.primary),
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

  /// Opens the device sheet, which shows the connected Chromecast with its
  /// "Deconectare" action.
  Widget _chromecastButton({required Key key}) {
    return BarIconButton(
      key: key,
      icon: Icons.cast_connected_rounded,
      color: AppColors.primary,
      tooltip: 'Dispozitiv conectat',
      height: widget.height,
      onPressed: () => showCastDevicePicker(context, source: 'app_bar'),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Device bottom sheet — live-updating, unified
// ═══════════════════════════════════════════════════════════════════

/// What the Chromecast card shows.
enum _CastCardState {
  /// Audio plays on a Chromecast; the card offers to disconnect it.
  connected,

  /// iOS blocks the local network, so no Chromecast can be found.
  blocked,

  /// The scan found Chromecasts on the Wi-Fi.
  found,

  /// The scan runs and has found nothing yet.
  searching,

  /// The scan ended without finding anything.
  empty,
}

class _DeviceSheet extends StatefulWidget {
  final CastService? castService;
  const _DeviceSheet({required this.castService});

  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> {
  /// How long a scan shows as running: mDNS can take up to 15s.
  static const _searchDuration = Duration(seconds: 15);

  final List<StreamSubscription> _subs = [];
  Timer? _searchTimer;

  List<GoogleCastDevice> _devices = [];
  bool _chromecastCasting = false;
  String? _connectedDeviceName;
  bool _searching = true;

  /// iOS Local Network access, which Chromecast discovery needs. `null`
  /// until the native check answers, and on platforms without it.
  LocalNetworkAccess? _localNetwork;
  bool _deniedReported = false;

  _CastCardState get _cardState {
    if (_chromecastCasting) return _CastCardState.connected;
    // Retrying won't help until the user allows it in Settings.
    if (_localNetwork == LocalNetworkAccess.denied) {
      return _CastCardState.blocked;
    }
    if (_devices.isNotEmpty) return _CastCardState.found;
    return _searching ? _CastCardState.searching : _CastCardState.empty;
  }

  @override
  void initState() {
    super.initState();

    // Listen to live device/state streams so the sheet updates in real-time
    final cs = widget.castService;
    if (cs != null) {
      _devices = cs.devices.value;
      _chromecastCasting = cs.isCasting.value;
      _connectedDeviceName = cs.connectedDeviceName.value;

      // Discovery runs continuously from app init (or from the first
      // cast button tap on iOS) — the sheet just reflects the live
      // device list. Do NOT restart here: on a cold
      // launch the first mDNS announcements usually omit the
      // `_CC1AD845` subtype, so the SDK must TCP-probe each device
      // (~20s). Restarting the scan on every open cancels those
      // in-flight probes and forces the whole cycle to start over,
      // which makes the sheet look empty when devices were seconds
      // away from publishing. Manual refresh is available via the
      // "Caută din nou" buttons on the card.

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
    _subs.add(LocalNetworkAccessMonitor.watch().listen(_onLocalNetworkAccess));

    _startSearchTimer();
  }

  void _onLocalNetworkAccess(LocalNetworkAccess access) {
    if (!mounted) return;
    final regained = _localNetwork == LocalNetworkAccess.denied &&
        access == LocalNetworkAccess.granted;
    setState(() => _localNetwork = access);
    // The scan found nothing while blocked; run it again now that it can.
    if (regained) _rescan();
    if (access == LocalNetworkAccess.denied && !_deniedReported) {
      _deniedReported = true;
      AnalyticsService.instance.capture('cast_local_network_denied');
    }
  }

  Future<void> _openAppSettings() async {
    AnalyticsService.instance.capture('cast_local_network_settings_opened');
    try {
      await launchUrl(Uri.parse('app-settings:'));
    } catch (e) {
      debugPrint('$runtimeType: opening Settings failed: $e');
    }
  }

  void _startSearchTimer() {
    // A new scan gets its full time, rather than ending with the old one.
    _searchTimer?.cancel();
    _searchTimer = Timer(_searchDuration, () {
      if (mounted) setState(() => _searching = false);
    });
  }

  void _rescan() {
    widget.castService?.restartDiscovery();
    setState(() => _searching = true);
    _startSearchTimer();
  }

  Future<void> _connect(GoogleCastDevice device) async {
    Navigator.of(context).pop();
    await widget.castService?.connectToDevice(device);
  }

  void _disconnect() {
    widget.castService?.disconnect();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    for (final s in _subs) { s.cancel(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      // Scrolls only when large text makes it taller than the screen.
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHeader(),
            _CastCard(
              state: _cardState,
              devices: _devices,
              searching: _searching,
              connectedDeviceName: _connectedDeviceName,
              onConnect: _connect,
              onDisconnect: _disconnect,
              onRescan: _rescan,
              onOpenSettings: _openAppSettings,
            ),
            const _SectionLabel('SAU'),
            // AirPlay — native picker (handles connect & disconnect)
            if (Platform.isIOS) const _AirPlayRow(),
            _DeviceRow(
              icon: Icons.tv_rounded,
              title: 'Aplicația pe televizor',
              subtitle: 'Android TV și Apple TV',
              beta: true,
              onTap: () => _showSheet(context, const _TvInstructionsSheet()),
            ),
            _DeviceRow(
              icon: Icons.directions_car_rounded,
              title: 'În mașină',
              subtitle: 'Android Auto și Apple CarPlay',
              onTap: () => _showSheet(context, const _CarInstructionsSheet()),
            ),
          ],
        ),
      ),
    );
  }
}

/// The icon for a Chromecast, from the words in its name and model, in
/// Romanian or English ("Televizor sufragerie", "Nest Audio").
IconData _chromecastIcon(GoogleCastDevice device) {
  final words =
      '${device.friendlyName} ${device.modelName ?? ''}'.toLowerCase();
  bool has(List<String> keys) => keys.any(words.contains);
  // Before the speakers: a "Nest Hub" is a display.
  if (has(const ['display', 'hub'])) return Icons.tablet_rounded;
  if (has(const ['tv', 'televizor', 'television'])) return Icons.tv_rounded;
  if (has(const ['speaker', 'nest', 'home', 'audio', 'boxă', 'boxa',
      'difuzor'])) {
    return Icons.speaker_rounded;
  }
  return Icons.cast_rounded;
}

// ═══════════════════════════════════════════════════════════════════
// Sheet header
// ═══════════════════════════════════════════════════════════════════

/// The drag handle at the top of each device sheet.
class _DragHandle extends StatelessWidget {
  final EdgeInsetsGeometry margin;

  const _DragHandle({this.margin = const EdgeInsets.only(top: 10, bottom: 14)});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: margin,
        decoration: BoxDecoration(
          color: Theme.of(context).deviceSheetColors.handle,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// The sheet's title, and the kinds of devices it offers.
class _SheetHeader extends StatelessWidget {
  const _SheetHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _DragHandle(),
          Text(
            'Ascultă pe alt dispozitiv',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            // Android has no AirPlay and Bluetooth row, so no headphones.
            Platform.isIOS
                ? 'Televizor, boxe, căști sau mașină'
                : 'Televizor, boxe sau mașină',
            style: TextStyle(
              fontSize: 14,
              color: theme.deviceSheetColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Chromecast card
// ═══════════════════════════════════════════════════════════════════

/// The Chromecast card: the scan, the devices it found, why it found none,
/// or the device audio plays on.
///
/// It keeps at least [minHeight], so the sheet keeps its height as a scan
/// starts, finds devices or ends.
class _CastCard extends StatelessWidget {
  static const double minHeight = 212;

  final _CastCardState state;
  final List<GoogleCastDevice> devices;
  final bool searching;
  final String? connectedDeviceName;
  final ValueChanged<GoogleCastDevice> onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onRescan;
  final VoidCallback onOpenSettings;

  const _CastCard({
    required this.state,
    required this.devices,
    required this.searching,
    required this.connectedDeviceName,
    required this.onConnect,
    required this.onDisconnect,
    required this.onRescan,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).deviceSheetColors;
    final content = switch (state) {
      _CastCardState.connected => _ConnectedChromecast(
          deviceName: connectedDeviceName,
          onDisconnect: onDisconnect,
        ),
      _CastCardState.blocked => _CardMessage(
          leading: _IconBubble(
            icon: Icons.lock_outline_rounded,
            background: colors.tint,
            color: colors.accent,
            size: 44,
          ),
          title: 'Permite accesul la rețeaua locală',
          body: 'Așa găsim televizorul sau boxa din Wi-Fi-ul tău.',
          button: _CardButton(
            label: 'Deschide Setările',
            icon: Icons.north_east_rounded,
            iconAlignment: IconAlignment.end,
            onPressed: onOpenSettings,
          ),
        ),
      _CastCardState.found => _FoundDevices(
          devices: devices,
          searching: searching,
          onConnect: onConnect,
          onRescan: onRescan,
        ),
      _CastCardState.searching => const _CardMessage(
          leading: _PulsingCastIcon(),
          title: 'Căutăm televizoare și boxe',
          body: 'în rețeaua ta Wi-Fi · durează câteva secunde',
        ),
      _CastCardState.empty => _CardMessage(
          title: 'Nu am găsit niciun dispozitiv',
          body: 'Verifică dacă telefonul și televizorul sunt conectate la '
              'același Wi-Fi și dacă televizorul e pornit.',
          button: _CardButton(
            label: 'Caută din nou',
            icon: Icons.refresh_rounded,
            onPressed: onRescan,
          ),
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: colors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        clipBehavior: Clip.antiAlias,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            switchInCurve: Curves.easeInOut,
            switchOutCurve: Curves.easeInOut,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, if (current != null) current],
            ),
            child: KeyedSubtree(key: ValueKey(state), child: content),
          ),
        ),
      ),
    );
  }
}

/// A centered message on the card: what happens or went wrong, and the
/// button that helps.
class _CardMessage extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String body;
  final Widget? button;

  const _CardMessage({
    this.leading,
    required this.title,
    required this.body,
    this.button,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final leading = this.leading;
    final button = this.button;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _CastCard.minHeight),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading, const SizedBox(height: 16)],
              Semantics(
                liveRegion: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: theme.deviceSheetColors.textSecondary,
                ),
              ),
              if (button != null) ...[const SizedBox(height: 14), button],
            ],
          ),
        ),
      ),
    );
  }
}

/// The card's filled pink button ("Caută din nou", "Deschide Setările").
class _CardButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final IconAlignment iconAlignment;
  final VoidCallback onPressed;

  const _CardButton({
    required this.label,
    required this.icon,
    this.iconAlignment = IconAlignment.start,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      iconAlignment: iconAlignment,
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.deviceAction,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// The Chromecasts the scan found, each one tap from playing.
class _FoundDevices extends StatelessWidget {
  final List<GoogleCastDevice> devices;
  final bool searching;
  final ValueChanged<GoogleCastDevice> onConnect;
  final VoidCallback onRescan;

  const _FoundDevices({
    required this.devices,
    required this.searching,
    required this.onConnect,
    required this.onRescan,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).deviceSheetColors;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _CastCard.minHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionLabel(
            'GĂSITE ÎN WI-FI-UL TĂU',
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            // The scan keeps looking for more; once it ends, the user can
            // start it again for a device that's missing.
            trailing: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: searching
                  ? SizedBox.square(
                      key: const ValueKey('searching'),
                      dimension: 44,
                      child: Center(
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: colors.pulse,
                            semanticsLabel: 'Se caută',
                          ),
                        ),
                      ),
                    )
                  : IconButton(
                      key: const ValueKey('rescan'),
                      onPressed: onRescan,
                      tooltip: 'Caută din nou',
                      constraints:
                          const BoxConstraints.tightFor(width: 44, height: 44),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.refresh_rounded,
                        size: 20,
                        color: colors.label,
                      ),
                    ),
            ),
          ),
          for (final device in devices)
            _ChromecastRow(device: device, onTap: () => onConnect(device)),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// A Chromecast the scan found; a tap plays the station on it.
class _ChromecastRow extends StatelessWidget {
  final GoogleCastDevice device;
  final VoidCallback onTap;

  const _ChromecastRow({required this.device, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).deviceSheetColors;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            children: [
              _IconBubble(
                icon: _chromecastIcon(device),
                background: colors.cardInner,
                color: colors.icon,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _RowTexts(
                  title: device.friendlyName,
                  subtitle: device.modelName,
                ),
              ),
              const SizedBox(width: 8),
              // The whole row connects; the pill says what a tap does.
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: colors.cardInner,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  'Conectează',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.accent,
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

/// The Chromecast audio plays on, with the button that stops it.
class _ConnectedChromecast extends StatelessWidget {
  final String? deviceName;
  final VoidCallback onDisconnect;

  const _ConnectedChromecast({
    required this.deviceName,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).deviceSheetColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel(
          'CONECTAT',
          padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, 16),
          child: Row(
            children: [
              const _IconBubble(
                icon: Icons.cast_connected_rounded,
                background: AppColors.deviceAction,
                color: Colors.white,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _RowTexts(
                  title: deviceName ?? 'Chromecast',
                  titleWeight: FontWeight.w600,
                  subtitle: 'Se aude acum',
                  subtitleColor: colors.accent,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onDisconnect,
                style: TextButton.styleFrom(
                  backgroundColor: colors.cardInner,
                  foregroundColor: colors.accent,
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: const StadiumBorder(),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Deconectează'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The cast icon in a pink circle, with rings spreading out of it while the
/// scan runs. Reduce Motion keeps it still.
class _PulsingCastIcon extends StatefulWidget {
  const _PulsingCastIcon();

  @override
  State<_PulsingCastIcon> createState() => _PulsingCastIconState();
}

class _PulsingCastIconState extends State<_PulsingCastIcon>
    with SingleTickerProviderStateMixin {
  static const double _size = 56;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ringColor = Theme.of(context).deviceSheetColors.pulse;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: _size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (!MediaQuery.disableAnimationsOf(context))
              for (final phase in const [0.0, 0.5])
                Positioned.fill(
                  child: _PulseRing(
                    animation: _controller,
                    phase: phase,
                    color: ringColor,
                  ),
                ),
            const Positioned.fill(
              child: _IconBubble(
                icon: Icons.cast_rounded,
                background: AppColors.deviceAction,
                color: Colors.white,
                size: _size,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One ring that grows out of the searching icon and fades as it goes.
class _PulseRing extends AnimatedWidget {
  /// Where in the loop this ring starts, so two rings take turns.
  final double phase;
  final Color color;

  const _PulseRing({
    required Animation<double> animation,
    required this.phase,
    required this.color,
  }) : super(listenable: animation);

  Animation<double> get _progress => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) {
    final t = (_progress.value + phase) % 1;
    return Transform.scale(
      scale: 1 + 1.1 * Curves.easeOut.transform(t),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withValues(alpha: 0.55 * (1 - t)),
            width: 2,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Row widgets
// ═══════════════════════════════════════════════════════════════════

/// A small all-caps label over a group of rows, with an optional control
/// at its end.
class _SectionLabel extends StatelessWidget {
  final String text;
  final EdgeInsetsGeometry padding;
  final Widget? trailing;

  const _SectionLabel(
    this.text, {
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 4),
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final trailing = this.trailing;
    final label = Semantics(
      header: true,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: Theme.of(context).deviceSheetColors.label,
        ),
      ),
    );
    return Padding(
      padding: padding,
      child: trailing == null
          ? label
          : ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(children: [Expanded(child: label), trailing]),
            ),
    );
  }
}

/// An icon in a filled circle.
class _IconBubble extends StatelessWidget {
  final IconData icon;
  final Color background;
  final Color color;
  final double size;

  const _IconBubble({
    required this.icon,
    required this.background,
    required this.color,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Icon(icon, size: 22, color: color),
    );
  }
}

/// A row's title, with an optional badge after it, and the line under it.
class _RowTexts extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? titleTrailing;
  final FontWeight titleWeight;
  final Color? subtitleColor;

  const _RowTexts({
    required this.title,
    this.subtitle,
    this.titleTrailing,
    this.titleWeight = FontWeight.w500,
    this.subtitleColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = this.subtitle;
    final titleTrailing = this.titleTrailing;
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 16,
        fontWeight: titleWeight,
        color: theme.colorScheme.onSurface,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (titleTrailing == null)
          titleText
        else
          Row(
            children: [
              Flexible(child: titleText),
              const SizedBox(width: 8),
              titleTrailing,
            ],
          ),
        if (subtitle != null && subtitle.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: subtitleColor ?? theme.deviceSheetColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// Another way to listen, under "SAU": a tap opens how to set it up.
class _DeviceRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool beta;

  const _DeviceRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.beta = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).deviceSheetColors;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 9, 16, 9),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: Icon(icon, size: 22, color: colors.icon),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _RowTexts(
                  title: title,
                  subtitle: subtitle,
                  titleTrailing: beta ? const _BetaBadge() : null,
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, size: 20, color: colors.chevron),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small on-brand "BETA" pill used to flag features still in testing.
class _BetaBadge extends StatelessWidget {
  const _BetaBadge();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).deviceSheetColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.beta,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'BETA',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: colors.accent,
        ),
      ),
    );
  }
}

/// AirPlay row with native picker overlay — always shows, handles both connect & disconnect.
class _AirPlayRow extends StatelessWidget {
  const _AirPlayRow();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const _DeviceRow(
          icon: Icons.airplay_rounded,
          title: 'AirPlay și Bluetooth',
          subtitle: 'Căști, boxe, HomePod, Apple TV',
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
            const _DragHandle(margin: EdgeInsets.only(bottom: 20)),

            const Icon(Icons.tv_rounded, size: 48, color: AppColors.primary),
            const SizedBox(height: 12),
            const _BetaBadge(),
            const SizedBox(height: 12),
            Text('Ascultă Radio Creștin pe televizor',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700, color: onSurface)),
            const SizedBox(height: 8),
            Text(
              'Aplicația pentru TV este în versiune beta — instaleaz-o direct '
              'pe televizor pentru cea mai bună experiență.',
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
            const _DragHandle(margin: EdgeInsets.only(bottom: 20)),

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

