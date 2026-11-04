import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_airplay/flutter_airplay.dart' as flutter_airplay;
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/utils/share_utils.dart';
import 'package:radio_crestin/widgets/share_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../appAudioHandler.dart';
import '../globals.dart' as globals;
import '../main.dart' show getIt;
import '../services/analytics_service.dart';
import '../services/android_renderer.dart';
import '../services/default_settings.dart';
import '../services/local_log_store.dart';
import '../services/log_upload_service.dart';
import '../services/playback_preferences.dart';
import '../services/station_data_service.dart';
import 'HiddenStationsPage.dart';
import 'LogsViewerPage.dart';
import '../seek_mode_manager.dart';
import '../theme.dart';
import '../theme_manager.dart';
import '../tv/desktop/desktop_smooth_scroll.dart';
import '../tv/desktop/now_playing_share_menu.dart';
import '../tv/desktop/settings_links.dart';
import '../tv/desktop/settings_panel.dart';
import '../tv/tv_platform.dart';
import '../widgets/bottom_toast.dart';
import '../widgets/pinned_title_sliver_header.dart';


class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.shareLinkData});

  final ShareLinkData? shareLinkData;

  /// Pushes the page onto the navigation stack, with the platform's page
  /// transition: on iOS it slides in from the right, and a swipe from the
  /// left edge takes it back.
  ///
  /// On desktop it opens in a panel centered over the window instead
  /// (see [showDesktopSettingsPanel]).
  static void show(BuildContext context, {ShareLinkData? shareLinkData}) {
    if (TvPlatform.isDesktop) {
      showDesktopSettingsPanel(
        context,
        home: (_) => SettingsPage(shareLinkData: shareLinkData),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        // Named so PostHog records a `$screen` for it.
        settings: const RouteSettings(name: '/settings'),
        builder: (_) => SettingsPage(shareLinkData: shareLinkData),
      ),
    );
  }

  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _notificationsEnabled = true;
  bool _autoStartStation = true;
  ThemeMode _themeMode = ThemeManager.themeMode.value;
  SeekMode _seekMode = SeekModeManager.seekMode.value;
  bool _unstableConnection = SeekModeManager.isUnstableConnection;
  bool _carConnected = SeekModeManager.isCarConnected;
  bool _preferDirectStreams = PlaybackPreferences.preferDirectStreams.value;
  final String _version = globals.appVersion;
  final String _buildNumber = globals.buildNumber;
  final String _deviceId = globals.deviceId;
  ShareLinkData? _shareLinkData;
  int? _visitCount;

  /// Developer mode, turned on with the "Mod dezvoltator" switch.
  bool _developerMode = false;

  /// The desktop list's own controller, for a mouse wheel that glides. The
  /// phone's list has none: it scrolls with the route's
  /// [PrimaryScrollController], the one iOS scrolls to the top on a tap on
  /// the status bar.
  final DesktopScrollController? _desktopScroll =
      TvPlatform.isDesktop ? DesktopScrollController() : null;

  /// The controller the settings list scrolls with, scrolled to the
  /// developer tools once the switch shows them.
  ScrollController? get _listScroll =>
      _desktopScroll ?? PrimaryScrollController.maybeOf(context);
  final GlobalKey _developerSectionKey =
      GlobalKey(debugLabel: 'developer section');

  /// Room kept above the Developer section's title when it is scrolled to,
  /// clear of the phone's pinned "Setări" bar.
  static const double _revealMargin = 72;
  bool _uploadingLogs = false;
  final AndroidRenderer _renderer = AndroidRenderer.instance;
  late RendererChoice _rendererChoice = _renderer.choice;

  // Stream diagnostics — re-rendered live so the user can watch fallbacks
  // happen while listening.
  StreamInfo? _streamInfo;
  List<StreamEvent> _streamEvents = const [];
  StreamSubscription<StreamInfo?>? _streamInfoSub;
  StreamSubscription<List<StreamEvent>>? _streamEventsSub;
  Timer? _diagnosticTicker;

  final StationDataService _stationDataService = getIt<StationDataService>();
  late int _hiddenCount = _stationDataService.hiddenStations.length;
  StreamSubscription<List<String>>? _hiddenSub;

  /// Whether the page is the desktop app's (a Mac, Windows or Linux),
  /// which leaves out what only a phone has: the theme picker (desktop is
  /// dark only), push notifications and the car.
  bool get _isDesktop => TvPlatform.isDesktop;


  @override
  void initState() {
    super.initState();
    _readStoredPreferences();
    SeekModeManager.carConnected.addListener(_onCarConnectionChanged);
    _liveSettings.addListener(_onLiveSettingsChanged);
    // The last known link shows its count at once; _loadShareData
    // refreshes it.
    final shareLinkData = widget.shareLinkData ?? ShareLinkCache.read();
    if (shareLinkData != null) {
      _shareLinkData = shareLinkData;
      _visitCount = shareLinkData.visitCount;
    }
    _loadShareData();
    _hiddenSub = _stationDataService.hiddenStationSlugs.stream.listen((_) {
      if (!mounted) return;
      setState(
          () => _hiddenCount = _stationDataService.hiddenStations.length);
    });

    final audioHandler = getIt<AppAudioHandler>();
    _streamInfo = audioHandler.currentStreamInfo.valueOrNull;
    _streamEvents = audioHandler.recentStreamEvents.value;
    if (!kReleaseMode) {
      _streamInfoSub = audioHandler.currentStreamInfo.listen((info) {
        if (mounted) setState(() => _streamInfo = info);
      });
      _streamEventsSub = audioHandler.recentStreamEvents.listen((events) {
        if (mounted) setState(() => _streamEvents = events);
      });
      // Re-render every 5s so the "playing for X" line stays current.
      _diagnosticTicker = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    SeekModeManager.carConnected.removeListener(_onCarConnectionChanged);
    _liveSettings.removeListener(_onLiveSettingsChanged);
    _streamInfoSub?.cancel();
    _streamEventsSub?.cancel();
    _diagnosticTicker?.cancel();
    _hiddenSub?.cancel();
    _desktopScroll?.dispose();
    super.dispose();
  }

  void _onCarConnectionChanged() {
    if (mounted) {
      setState(() {
        _carConnected = SeekModeManager.isCarConnected;
      });
    }
  }

  /// The settings PostHog's defaults may change while the page is open.
  static final Listenable _liveSettings = Listenable.merge([
    ThemeManager.themeMode,
    SeekModeManager.seekMode,
    SeekModeManager.unstableConnection,
    PlaybackPreferences.preferDirectStreams,
  ]);

  void _onLiveSettingsChanged() {
    if (!mounted) return;
    setState(() {
      _themeMode = ThemeManager.themeMode.value;
      _seekMode = SeekModeManager.seekMode.value;
      _unstableConnection = SeekModeManager.isUnstableConnection;
      _preferDirectStreams = PlaybackPreferences.preferDirectStreams.value;
    });
  }

  /// Reads the saved toggles from the instance loaded at startup.
  ///
  /// Synchronous on purpose: the route opens without a transition, so an
  /// async read showed a blank page until the frame after the result came
  /// back.
  void _readStoredPreferences() {
    final prefs = getIt<SharedPreferences>();
    _notificationsEnabled = prefs.getBool('_notificationsEnabled') ?? true;
    _autoStartStation = prefs.getBool('_autoStartStation') ?? true;
    _developerMode = prefs.getBool('developer_mode_enabled') ?? false;
  }


  void _shareApp(BuildContext context) {
    final fallbackUrl = 'https://www.radiocrestin.ro/descarca-aplicatia-radio-crestin';
    ShareSheet.show(
      context,
      shareUrl: _shareLinkData?.generateShareUrl() ?? fallbackUrl,
      shareMessage: 'Instalează și tu aplicația Radio Creștin și ascultă peste 60 de stații de radio creștin:\n$fallbackUrl',
      initialData: _shareLinkData,
      loader: _shareLinkData == null ? _fetchShareLink : null,
    );
  }

  Widget _buildSectionHeader(String title) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 28, bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: isDark ? const Color(0xff8a8a8a) : const Color(0xff6b6b6b),
        ),
      ),
    );
  }

  Widget _buildSettingsCard({required List<Widget> children}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const radius = Radius.circular(16);
    final positionedChildren = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      final isFirst = i == 0;
      final isLast = i == children.length - 1;
      final borderRadius = BorderRadius.only(
        topLeft: isFirst ? radius : Radius.zero,
        topRight: isFirst ? radius : Radius.zero,
        bottomLeft: isLast ? radius : Radius.zero,
        bottomRight: isLast ? radius : Radius.zero,
      );
      final child = children[i];
      if (child is ListTile) {
        positionedChildren.add(ListTile(
          contentPadding: child.contentPadding,
          titleAlignment: child.titleAlignment,
          shape: RoundedRectangleBorder(borderRadius: borderRadius),
          leading: child.leading,
          title: child.title,
          subtitle: child.subtitle,
          trailing: child.trailing,
          onTap: child.onTap,
        ));
      } else {
        positionedChildren.add(child);
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      // A Material, not a colored Container: ListTile paints its ink on the
      // nearest Material, so a colored box in between would hide the ripple.
      child: Material(
        color: isDark ? const Color(0xff1c1c1e) : const Color(0xfff2f2f7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: _insertDividers(positionedChildren),
        ),
      ),
    );
  }

  List<Widget> _insertDividers(List<Widget> children) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final result = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      result.add(children[i]);
      if (i < children.length - 1) {
        result.add(Padding(
          padding: const EdgeInsets.only(left: 56),
          child: Divider(
            height: 0.5,
            thickness: 0.5,
            color: isDark ? const Color(0xff3a3a3c) : const Color(0xffd1d1d6),
          ),
        ));
      }
    }
    return result;
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? subtitleWidget,
    Widget? trailing,
    VoidCallback? onTap,
    FocusNode? focusNode,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtitleContent = subtitleWidget ??
        (subtitle != null
            ? Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: isDark ? const Color(0xff8a8a8a) : const Color(0xff6b6b6b)))
            : null);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      titleAlignment: ListTileTitleAlignment.center,
      leading: Icon(
        icon,
        size: 22,
        color: isDark ? const Color(0xffb0b0b0) : const Color(0xff5a5a5a),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: isDark ? const Color(0xffe8e8e8) : const Color(0xff1c1c1e),
        ),
      ),
      subtitle: subtitleContent,
      trailing: trailing ?? Icon(Icons.chevron_right, size: 20, color: isDark ? const Color(0xff5a5a5c) : const Color(0xffc7c7cc)),
      onTap: onTap,
      focusNode: focusNode,
    );
  }

  /// How many friends opened the user's invitation, or what the row does
  /// before anyone did.
  Widget _buildShareAppSubtitle(bool isDark) {
    final visitCount = _visitCount;
    if (visitCount != null && visitCount > 0) {
      return _InviteCountSubtitle(count: visitCount);
    }
    return Text(
      'Trimite linkul tău prietenilor și familiei',
      style: TextStyle(
        fontSize: 12,
        color: isDark ? const Color(0xff8a8a8a) : const Color(0xff6b6b6b),
      ),
    );
  }

  /// "Distribuie aplicația" on desktop: a menu opening at the row
  /// (WhatsApp, Facebook, copy, the system share) rather than the phone's
  /// sheet rising from the window's bottom.
  Widget _buildDesktopShareAppTile(Widget subtitle) {
    return DesktopShareMenu(
      station: null,
      initialLink: _shareLinkData,
      loader: _fetchShareLink,
      onOpened: () => AnalyticsService.instance
          .capture('button_clicked', {'button_name': 'share_app'}),
      builder: (context, toggle, focusNode) => _buildSettingsTile(
        icon: Icons.share_rounded,
        title: 'Distribuie aplicația',
        subtitleWidget: subtitle,
        onTap: toggle,
        focusNode: focusNode,
      ),
    );
  }

  /// Fetches the user's personal share link, for the phone's share sheet
  /// and the desktop's share menu.
  Future<ShareLinkData?> _fetchShareLink() =>
      ShareService(getIt<AppAudioHandler>().graphqlClient)
          .getPersonalShareLink();

  bool get _isCasting {
    final h = getIt<AppAudioHandler>();
    return h.isCasting;
  }

  bool get _isAirPlayActive =>
      Platform.isIOS && flutter_airplay.AirPlayRouteState.instance.isActive;

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
  }

  String _formatStreamType(String? type) {
    if (type == null || type.isEmpty) return 'necunoscut';
    switch (type.toUpperCase()) {
      case 'HLS':
        return 'HLS';
      case 'PROXIED_STREAM':
        return 'Stream direct (proxy)';
      case 'DIRECT_STREAM':
      case 'DIRECT_MP3':
        return 'MP3 direct';
      default:
        return type;
    }
  }

  String _formatEventTime(DateTime t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  String _streamEventLabel(StreamEvent e) => '${_formatEventTime(e.timestamp)} — ${e.message}';

  Color _eventColor(StreamEvent e, bool isDark) {
    switch (e.kind) {
      case StreamEventKind.loaded:
      case StreamEventKind.attempt:
      case StreamEventKind.lifecycle:
        return isDark ? const Color(0xff8e8e93) : const Color(0xff6b6b6b);
      case StreamEventKind.switched:
        return const Color(0xff34c759);
      case StreamEventKind.failed:
      case StreamEventKind.bufferingStall:
      case StreamEventKind.nonHlsCompleted:
      case StreamEventKind.playerError:
        return const Color(0xffff3b30);
      case StreamEventKind.hlsCompleted:
      case StreamEventKind.lostIdle:
      case StreamEventKind.bufferingDrop:
      case StreamEventKind.audioInterruption:
      case StreamEventKind.hlsStalled:
        return const Color(0xffff9500);
    }
  }

  Widget _buildDiagnosticCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final info = _streamInfo;
    final events = _streamEvents;

    String? primaryLine;
    String? secondaryLine;

    if (_isCasting) {
      primaryLine = 'Cast activ';
      secondaryLine = 'Redarea este pe dispozitivul Cast — streamul local nu rulează.';
    } else if (_isAirPlayActive) {
      primaryLine = 'AirPlay activ';
      secondaryLine = 'Audio rutat prin AirPlay.';
    } else if (info == null) {
      primaryLine = 'Niciun stream încărcat';
      secondaryLine = 'Pornește o stație pentru a vedea detaliile.';
    } else {
      final indexLabel = info.totalStreams > 0
          ? 'Stream ${info.attemptIndex + 1}/${info.totalStreams}'
          : 'Stream curent';
      primaryLine = '${_formatStreamType(info.type)} • $indexLabel';
      final since = DateTime.now().difference(info.loadedAt);
      secondaryLine = '${info.host} • redă de ${_formatDuration(since)}';
    }

    final children = <Widget>[];

    children.add(_buildSettingsTile(
      icon: Icons.podcasts,
      title: primaryLine,
      subtitle: secondaryLine,
      trailing: info != null && !_isCasting && !_isAirPlayActive
          ? IconButton(
              icon: Icon(
                Icons.copy,
                size: 18,
                color: isDark ? const Color(0xff8a8a8a) : const Color(0xff6b6b6b),
              ),
              tooltip: 'Copiază URL',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: info.url));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('URL copiat'),
                      duration: const Duration(seconds: 2),
                      backgroundColor: AppColors.primaryDark,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  );
                }
              },
            )
          : const SizedBox(width: 0, height: 0),
    ));

    final visibleEvents = events.take(10).toList();
    if (visibleEvents.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(56, 4, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Evenimente recente',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: isDark ? const Color(0xff8a8a8a) : const Color(0xff6b6b6b),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _copyDiagnosticReport(events, info),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.content_copy_outlined,
                          size: 12,
                          color: isDark ? const Color(0xff8a8a8a) : const Color(0xff6b6b6b),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Copiază',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? const Color(0xff8a8a8a) : const Color(0xff6b6b6b),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final e in visibleEvents)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Text(
                  _streamEventLabel(e),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: _eventColor(e, isDark),
                  ),
                ),
              ),
          ],
        ),
      ));
    }

    return _buildSettingsCard(children: children);
  }

  Future<void> _copyDiagnosticReport(List<StreamEvent> events, StreamInfo? info) async {
    final buf = StringBuffer();
    buf.writeln('Radio Crestin diagnostic — v$_version ($_buildNumber)');
    buf.writeln('Device: $_deviceId');
    buf.writeln('Time: ${DateTime.now().toIso8601String()}');
    if (_isCasting) buf.writeln('Output: Cast');
    if (_isAirPlayActive) buf.writeln('Output: AirPlay');
    if (info != null) {
      buf.writeln('Station: ${info.stationTitle} (${info.stationSlug})');
      buf.writeln('Stream: ${info.type ?? '?'} ${info.attemptIndex + 1}/${info.totalStreams}');
      buf.writeln('URL: ${info.url}');
      buf.writeln('Loaded at: ${info.loadedAt.toIso8601String()}');
    } else {
      buf.writeln('Stream: (none)');
    }
    buf.writeln('--- Events (most recent first) ---');
    for (final e in events) {
      buf.writeln(_streamEventLabel(e));
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Raport copiat în clipboard'),
          duration: const Duration(seconds: 2),
          backgroundColor: AppColors.primaryDark,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  /// Trailing copy affordance shared by the "Despre aplicație" tiles.
  Widget _buildCopyIcon(bool isDark) {
    return Icon(
      Icons.copy,
      size: 18,
      color: isDark ? const Color(0xff8a8a8a) : const Color(0xff6b6b6b),
    );
  }

  /// Copies [value] to the clipboard and confirms via a SnackBar showing
  /// [confirmation]. Used by the "Despre aplicație" tiles so users can
  /// share these details for support without retyping them.
  Future<void> _copyAppInfoValue({
    required String buttonName,
    required String value,
    required String confirmation,
  }) async {
    AnalyticsService.instance.capture('button_clicked', {'button_name': buttonName});
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          confirmation,
          style: const TextStyle(color: Colors.white),
        ),
        duration: const Duration(seconds: 2),
        backgroundColor: AppColors.primaryDark,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// Writes a settings change to the log, so a listener's log file shows
  /// the mode playback ran in from then on.
  /// Applies "use MP3 streams first" from the next stream load: the playing
  /// stream keeps playing.
  Future<void> _changePreferDirectStreams(bool value) async {
    AnalyticsService.instance.capture('button_clicked',
        {'button_name': 'prefer_direct_streams', 'enabled': value});
    _logSettingChanged('prefer_direct_streams', value);
    setState(() => _preferDirectStreams = value);
    PlaybackPreferences.changePreferDirectStreams(value);
    await PlaybackPreferences.savePreferDirectStreams(value);
  }

  void _logSettingChanged(String setting, Object value) => AnalyticsService
      .instance
      .log('setting changed', {'setting': setting, 'value': value});

  // ── Developer mode ──

  Future<void> _setDeveloperMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('developer_mode_enabled', enabled);
    // Developer mode ships debug-level logs to PostHog for this device.
    AnalyticsService.instance.setDeveloperVerbose(enabled);
    AnalyticsService.instance
        .capture('developer_mode_toggled', {'enabled': enabled});
    _logSettingChanged('developer_mode', enabled);
    if (!mounted) return;
    setState(() => _developerMode = enabled);
    _showDevSnack(enabled
        ? 'Mod dezvoltator activat'
        : 'Mod dezvoltator dezactivat');
    if (enabled) _revealDeveloperSection();
  }

  /// Scrolls to the developer tools that just appeared at the end of the
  /// list, so the switch shows what it turned on: to the end, or less if
  /// that would take the section's title out of view.
  void _revealDeveloperSection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scroll = _listScroll;
      if (scroll == null || !scroll.hasClients) return;
      final position = scroll.position;
      var target = position.maxScrollExtent;
      final title = _developerSectionKey.currentContext?.findRenderObject();
      if (title is RenderBox && title.attached) {
        final titleAt =
            RenderAbstractViewport.of(title).getOffsetToReveal(title, 0).offset;
        target = math.min(target, titleAt - _revealMargin);
      }
      if (target <= position.pixels) return;
      scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    });
  }

  /// Saves the renderer for the next launch and, when it differs from the
  /// one this launch asked for, offers to restart the app right away.
  Future<void> _changeRenderer(RendererChoice? choice) async {
    if (choice == null || choice == _rendererChoice) return;
    AnalyticsService.instance.capture('button_clicked',
        {'button_name': 'renderer', 'renderer': choice.name});
    _logSettingChanged('renderer', choice.name);
    setState(() => _rendererChoice = choice);
    await _renderer.setChoice(choice);
    if (!mounted) return;
    if (_renderer.nextLaunchUsesSkia == _renderer.launchUsesSkia) return;
    final restart = await showDialog<bool>(
      context: context,
      builder: (_) => const _RestartForRendererDialog(),
    );
    if (restart == true) await _restartForRenderer();
  }

  /// Stops the radio, sends what is pending to PostHog, then restarts the
  /// app's process. Without a restart, the user is told how to apply it.
  Future<void> _restartForRenderer() async {
    try {
      await getIt<AppAudioHandler>()
          .stop()
          .timeout(const Duration(seconds: 2));
      await AnalyticsService.instance
          .flush()
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // The restart matters more than a clean stop.
    }
    try {
      await _renderer.restartApp();
    } catch (_) {
      _showDevSnack(
          'Închide aplicația și redeschide-o pentru a aplica schimbarea.');
    }
  }

  Future<void> _copyLogs() async {
    AnalyticsService.instance
        .capture('button_clicked', {'button_name': 'copy_logs'});
    final text = await LocalLogStore.instance.readRecent();
    if (text.isEmpty) {
      _showDevSnack('Niciun log de copiat');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _showDevSnack('Loguri copiate');
  }

  Future<void> _sendLogs() async {
    if (_uploadingLogs) return;
    AnalyticsService.instance
        .capture('button_clicked', {'button_name': 'send_logs'});
    setState(() => _uploadingLogs = true);
    final result = await LogUploadService.instance.upload(trigger: 'manual');
    if (!mounted) return;
    setState(() => _uploadingLogs = false);
    _showDevSnack(result.success
        ? 'Loguri trimise (${result.parts} părți)'
        : 'Trimiterea logurilor a eșuat. Încearcă din nou.');
  }

  void _showDevSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        duration: const Duration(seconds: 2),
        backgroundColor: AppColors.primaryDark,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final settings = CustomScrollView(
        controller: _desktopScroll,
        primary: _desktopScroll == null,
        slivers: [
          if (!_isDesktop) const PinnedTitleSliverHeader(title: 'Setări'),
          SliverSafeArea(
            top: false,
            sliver: SliverList.list(
              children: [
              // General section
              _buildSectionHeader('Preferințe'),
              _buildSettingsCard(children: [
                // Desktop is dark only, so there is no theme to pick.
                if (!_isDesktop) _buildSettingsTile(
                  icon: Icons.brightness_6,
                  title: 'Interfața temei',
                  trailing: DropdownButton<ThemeMode>(
                    value: _themeMode,
                    underline: const SizedBox(),
                    borderRadius: BorderRadius.circular(12),
                    onChanged: (ThemeMode? newValue) async {
                      if (newValue != null) {
                        AnalyticsService.instance.capture('button_clicked', {'button_name': 'theme_mode', 'theme_mode': newValue.name});
                        _logSettingChanged('theme', newValue.name);
                        setState(() {
                          _themeMode = newValue;
                        });
                        await ThemeManager.saveThemeMode(newValue);
                        ThemeManager.changeThemeMode(newValue);
                        await DefaultSettings.markUserSet(
                            AppDefaultSettings.themeMode);
                      }
                    },
                    items: const [
                      DropdownMenuItem(
                        value: ThemeMode.system,
                        child: Text('Sistem', style: TextStyle(fontSize: 14)),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text('Luminos', style: TextStyle(fontSize: 14)),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text('Întunecat', style: TextStyle(fontSize: 14)),
                      ),
                    ],
                  ),
                ),
                _buildSettingsTile(
                  icon: _carConnected
                      ? Icons.directions_car
                      : Icons.signal_wifi_statusbar_connected_no_internet_4,
                  title: 'Conexiune instabilă',
                  subtitle: _carConnected
                      ? 'În timpul condusului, economisirea de date este activă.'
                      : 'Activează dacă viteza internetului este slabă și instabilă.',
                  trailing: IgnorePointer(
                    ignoring: _carConnected,
                    child: Opacity(
                      opacity: _carConnected ? 0.4 : 1.0,
                      child: Switch.adaptive(
                        activeColor: Colors.white,
                        activeTrackColor: isDark ? const Color(0xff48a868) : const Color(0xff34c759),
                        inactiveThumbColor: Colors.white,
                        inactiveTrackColor: isDark ? const Color(0xff39393d) : const Color(0xffe9e9ea),
                        onChanged: (bool value) async {
                          AnalyticsService.instance.capture('button_clicked', {'button_name': 'unstable_connection', 'enabled': value});
                          _logSettingChanged('unstable_connection', value);
                          setState(() {
                            _unstableConnection = value;
                          });
                          await SeekModeManager.saveUnstableConnection(value);
                          SeekModeManager.changeUnstableConnection(value);
                          await DefaultSettings.markUserSet(
                              AppDefaultSettings.unstableConnection);
                          // The seek mode is left as it was: ON already forces
                          // 5 minutes (see SeekModeManager.currentOffset), and
                          // OFF gives back the user's mode, or the default one.
                          getIt<AppAudioHandler>().reapplySeekOffset();
                          getIt<AppAudioHandler>().refreshCurrentMetadata();
                          if (context.mounted) {
                            removeBottomToast(_activeToast);
                            _activeToast = showBottomToast(
                              context,
                              title: value ? 'Mod conexiune instabilă activat' : 'Mod conexiune instabilă dezactivat',
                              message: value
                                  ? 'Încărcare în avans setată la 5 minute. Doar miniaturile melodiilor vor fi afișate.'
                                  : 'Poți alege manual timpul de încărcare în avans.',
                              onDismissed: () { _activeToast = null; },
                            );
                          }
                        },
                        value: _carConnected || _unstableConnection,
                      ),
                    ),
                  ),
                ),
                _buildSettingsTile(
                  icon: Icons.network_check,
                  title: 'Încărcare în avans',
                  subtitle: _carConnected
                      ? 'În timpul condusului stațiile radio sunt preîncărcate 5 minute.'
                      : _unstableConnection
                          ? 'Blocat la 5 minute de modul conexiune instabilă.'
                          : null,
                  trailing: IgnorePointer(
                    ignoring: _carConnected || _unstableConnection,
                    child: Opacity(
                      opacity: (_carConnected || _unstableConnection) ? 0.4 : 1.0,
                      child: DropdownButton<SeekMode>(
                        value: (_carConnected || _unstableConnection) ? SeekMode.fiveMinutes : _seekMode,
                        underline: const SizedBox(),
                        borderRadius: BorderRadius.circular(12),
                        // Room around the value, so the pointer's highlight
                        // doesn't hug the text.
                        padding: _isDesktop
                            ? const EdgeInsets.symmetric(horizontal: 12)
                            : null,
                        onChanged: (SeekMode? newValue) async {
                          if (newValue != null) {
                            AnalyticsService.instance.capture('button_clicked', {'button_name': 'buffer_size', 'seek_mode': newValue.name});
                            _logSettingChanged('seek_mode', newValue.name);
                            setState(() {
                              _seekMode = newValue;
                            });
                            await SeekModeManager.saveSeekMode(newValue);
                            SeekModeManager.changeSeekMode(newValue);
                            await DefaultSettings.markUserSet(
                                AppDefaultSettings.seekMode);
                            getIt<AppAudioHandler>().reapplySeekOffset();
                            getIt<AppAudioHandler>().refreshCurrentMetadata();
                            if (context.mounted) {
                              final message = newValue == SeekMode.instant
                                  ? 'Acum asculți live cu un mic decalaj de câteva secunde.'
                                  : 'Radioul va avea un decalaj de ${newValue == SeekMode.twoMinutes ? '2' : '5'} minute față de live.';
                              removeBottomToast(_activeToast);
                              _activeToast = showBottomToast(
                                context,
                                title: 'Gata!',
                                message: message,
                                onDismissed: () { _activeToast = null; },
                              );
                            }
                          }
                        },
                        items: const [
                          DropdownMenuItem(
                            value: SeekMode.instant,
                            child: Text('Live', style: TextStyle(fontSize: 14)),
                          ),
                          DropdownMenuItem(
                            value: SeekMode.twoMinutes,
                            child: Text('2 minute', style: TextStyle(fontSize: 14)),
                          ),
                          DropdownMenuItem(
                            value: SeekMode.fiveMinutes,
                            child: Text('5 minute', style: TextStyle(fontSize: 14)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                _buildSettingsTile(
                  icon: Icons.radio,
                  title: 'Pornește automat ultima stație',
                  subtitle: 'La deschiderea aplicației',
                  trailing: Switch.adaptive(
                    activeColor: Colors.white,
                    activeTrackColor: isDark ? const Color(0xff48a868) : const Color(0xff34c759),
                    inactiveThumbColor: Colors.white,
                    inactiveTrackColor: isDark ? const Color(0xff39393d) : const Color(0xffe9e9ea),
                    onChanged: (bool value) async {
                      AnalyticsService.instance.capture('button_clicked', {'button_name': 'auto_start_station', 'enabled': value});
                      _logSettingChanged('auto_start', value);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('_autoStartStation', value);
                      await DefaultSettings.markUserSet(
                          AppDefaultSettings.autoStartStation);
                      if (!mounted) return;
                      setState(() {
                        _autoStartStation = value;
                      });
                    },
                    value: _autoStartStation,
                  ),
                ),
                // Push notifications reach phones only.
                if (!_isDesktop) _buildSettingsTile(
                  icon: Icons.notification_important_rounded,
                  title: 'Notificări personalizate',
                  subtitle: 'Primiți notificări când începe o melodie/emisiune preferată.',
                  trailing: Switch.adaptive(
                    activeColor: Colors.white,
                    activeTrackColor: isDark ? const Color(0xff48a868) : const Color(0xff34c759),
                    inactiveThumbColor: Colors.white,
                    inactiveTrackColor: isDark ? const Color(0xff39393d) : const Color(0xffe9e9ea),
                    onChanged: (bool value) async {
                      AnalyticsService.instance.capture('button_clicked', {'button_name': 'custom_notifications', 'enabled': value});
                      _logSettingChanged('notifications', value);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('_notificationsEnabled', value);
                      await DefaultSettings.markUserSet(
                          AppDefaultSettings.notificationsEnabled);
                      if (mounted) {
                        setState(() {
                          _notificationsEnabled = value;
                        });
                      }
                      AnalyticsService.instance.setUserProperty('personalized_n', value ? 'true' : 'false');
                    },
                    value: _notificationsEnabled,
                  ),
                ),
                _buildSettingsTile(
                  icon: Icons.visibility_off_outlined,
                  title: 'Stații ascunse',
                  subtitle: HiddenStationsPage.countText(_hiddenCount),
                  onTap: () {
                    AnalyticsService.instance.capture('button_clicked',
                        {'button_name': 'hidden_stations'});
                    HiddenStationsPage.show(context);
                  },
                ),
              ]),

              _buildSectionHeader('General'),
              _buildSettingsCard(children: [
                if (_isDesktop)
                  _buildDesktopShareAppTile(_buildShareAppSubtitle(isDark))
                else _buildSettingsTile(
                  icon: Icons.share_rounded,
                  title: 'Distribuie aplicația',
                  subtitleWidget: _buildShareAppSubtitle(isDark),
                  onTap: () {
                    AnalyticsService.instance.capture('button_clicked', {'button_name': 'share_app'});
                    _shareApp(context);
                  },
                ),
                // Windows and Linux have no store page to review.
                if (!_isDesktop || Platform.isMacOS) _buildSettingsTile(
                  icon: Icons.star_rounded,
                  title: 'Lasă-ne o recenzie',
                  onTap: () async {
                    AnalyticsService.instance.capture('button_clicked', {'button_name': 'leave_review'});
                    // The Mac app is the iPhone's, in the Mac App Store.
                    if (Platform.isMacOS) return openMacAppStoreReview();
                    final url = Platform.isIOS
                        ? 'https://apps.apple.com/app/6451270471?action=write-review'
                        : 'https://play.google.com/store/apps/details?id=com.radiocrestin.radio_crestin';
                    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                  },
                ),
                _buildSettingsTile(
                  icon: Icons.chat,
                  title: 'Contactează-ne pe WhatsApp',
                  onTap: () async {
                    AnalyticsService.instance.capture('whatsapp_contact');

                    final platform = Platform.isAndroid ? "Android" : Platform.isIOS ? "iOS" : desktopPlatformLabel(Platform.operatingSystem);
                    final message = "[RadioCrestin/$platform/v${globals.appVersion}/${globals.deviceId}]\n\nBuna ziua,\n";
                    launchUrl(
                        Uri.parse(
                            "https://wa.me/40766338046?text=${Uri.encodeFull(message)}"
                        ),
                        mode: LaunchMode.externalApplication);
                  },
                ),
              ]),

              if (!kReleaseMode) ...[
                _buildSectionHeader('Diagnostic redare'),
                _buildDiagnosticCard(),
              ],

              if (kDebugMode) ...[
                _buildSectionHeader('Debug'),
                _buildSettingsCard(children: [
                  if (!_isDesktop) _buildSettingsTile(
                    icon: Icons.directions_car,
                    title: 'CarPlay / Android Auto',
                    subtitle: _carConnected ? 'Conectat' : 'Deconectat',
                    trailing: Icon(
                      _carConnected ? Icons.check_circle : Icons.cancel,
                      size: 20,
                      color: _carConnected ? Colors.green : Colors.grey,
                    ),
                  ),
                  _buildSettingsTile(
                    icon: Icons.bug_report,
                    title: 'Test crash (PostHog)',
                    subtitle: 'Aruncă o excepție pentru a testa capturarea erorilor',
                    trailing: const Icon(Icons.warning_amber_rounded, size: 20, color: Colors.orange),
                    onTap: () {
                      throw Exception('Test crash from Settings — verifying PostHog error tracking');
                    },
                  ),
                  _buildSettingsTile(
                    icon: Icons.delete_sweep,
                    title: 'Șterge datele aplicației',
                    subtitle: 'Șterge preferințele și cache-ul',
                    trailing: const Icon(Icons.chevron_right, size: 20, color: Colors.redAccent),
                    onTap: () async {
                      showDialog(
                        context: context,
                        builder: (BuildContext context) {
                          return AlertDialog(
                            title: const Text('Confirmare ștergere'),
                            content: const Text('Ești sigur că vrei să ștergi toate datele salvate și cache-ul aplicației?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Anulează'),
                              ),
                              TextButton(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  final prefs = await SharedPreferences.getInstance();
                                  await prefs.clear();

                                  final audioHandler = getIt<AppAudioHandler>();
                                  audioHandler.graphqlClient.cache.store.reset();

                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: const Text(
                                        'Datele aplicației au fost șterse!',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      backgroundColor: AppColors.primaryDark,
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );

                                  setState(_readStoredPreferences);
                                },
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.red,
                                ),
                                child: const Text('Șterge'),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ]),
              ],
              _buildSectionHeader('Despre aplicație'),
              _buildSettingsCard(children: [
                _buildSettingsTile(
                  icon: Icons.info_outline_rounded,
                  title: 'Versiune',
                  subtitle: '$_version ($_buildNumber)',
                  trailing: _buildCopyIcon(isDark),
                  onTap: () => _copyAppInfoValue(
                    buttonName: 'copy_app_version',
                    value: '$_version ($_buildNumber)',
                    confirmation: 'Versiune copiată',
                  ),
                ),
                _buildSettingsTile(
                  icon: Icons.fingerprint,
                  title: 'ID dispozitiv',
                  subtitleWidget: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _deviceId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: isDark
                            ? const Color(0xff8a8a8a)
                            : const Color(0xff6b6b6b),
                      ),
                    ),
                  ),
                  trailing: _buildCopyIcon(isDark),
                  onTap: () => _copyAppInfoValue(
                    buttonName: 'copy_device_id',
                    value: _deviceId,
                    confirmation: 'ID dispozitiv copiat',
                  ),
                ),
              ]),

              KeyedSubtree(
                key: _developerSectionKey,
                child: _buildSectionHeader('Developer'),
              ),
              _buildSettingsCard(children: [
                _buildSettingsTile(
                  icon: Icons.developer_mode,
                  title: 'Mod dezvoltator',
                  subtitle: _developerMode ? 'Loguri detaliate activate' : null,
                  trailing: Switch.adaptive(
                    activeThumbColor: Colors.white,
                    activeTrackColor: isDark
                        ? const Color(0xff48a868)
                        : const Color(0xff34c759),
                    inactiveThumbColor: Colors.white,
                    inactiveTrackColor: isDark
                        ? const Color(0xff39393d)
                        : const Color(0xffe9e9ea),
                    value: _developerMode,
                    onChanged: _setDeveloperMode,
                  ),
                ),
              ]),
              // The tools fade in under the switch; at the end of the list,
              // nothing below them moves.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: !_developerMode
                    ? const SizedBox(key: ValueKey('developer-off'))
                    : _buildDeveloperTools(),
              ),
              const SizedBox(height: 40),
              ],
            ),
          ),
        ],
      );
    return Scaffold(
      body: _isDesktop
          ? DesktopSettingsFrame(title: 'Setări', child: settings)
          : settings,
    );
  }

  /// The developer tools shown while "Mod dezvoltator" is on. The device ID
  /// is not repeated here: "Despre aplicație" shows it, with a copy button.
  Widget _buildDeveloperTools() {
    return Padding(
      key: const ValueKey('developer-on'),
      padding: const EdgeInsets.only(top: 12),
      child: _buildSettingsCard(children: [
        // Windows and Linux always load MP3 streams first.
        if (!PlaybackPreferences.platformPrefersDirectStreams)
          _buildSettingsTile(
            icon: Icons.audiotrack_rounded,
            title: 'Folosește MP3 cu prioritate',
            subtitle: 'Activează dacă radioul se oprește sau nu '
                'pornește; ascultă live, fără preîncărcare.',
            trailing: _SettingsSwitch(
              value: _preferDirectStreams,
              onChanged: _changePreferDirectStreams,
            ),
          ),
        _buildSettingsTile(
          icon: Icons.article_outlined,
          title: 'Vezi logurile',
          subtitle: 'Logurile locale ale aplicației',
          onTap: () {
            AnalyticsService.instance.capture('button_clicked',
                {'button_name': 'view_logs'});
            LogsViewerPage.show(context);
          },
        ),
        _buildSettingsTile(
          icon: Icons.copy_all_outlined,
          title: 'Copiază logurile',
          subtitle: 'Cele mai recente (max. 200KB)',
          onTap: _copyLogs,
        ),
        _buildSettingsTile(
          icon: Icons.cloud_upload_outlined,
          title: 'Trimite logurile către noi',
          subtitle: 'Încarcă logurile pentru diagnosticare',
          trailing: _uploadingLogs
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: AppColors.primary,
                  ),
                )
              : null,
          onTap: _uploadingLogs ? null : _sendLogs,
        ),
        // iOS and macOS have Impeller only.
        if (_renderer.supported)
          _buildSettingsTile(
            icon: Icons.layers_outlined,
            title: 'Motor grafic',
            subtitle: 'Acum: ${_activeRendererName()}. '
                'Schimbarea se aplică la următoarea pornire '
                'a aplicației',
            trailing: _RendererDropdown(
              value: _rendererChoice,
              onChanged: _changeRenderer,
            ),
          ),
      ]),
    );
  }

  Future<void> _loadShareData() async {
    try {
      final audioHandler = getIt<AppAudioHandler>();
      final shareService = ShareService(audioHandler.graphqlClient);
      final data = await shareService.getShareLink(globals.deviceId);

      if (mounted && data != null) {
        setState(() {
          _shareLinkData = data;
          _visitCount = data.visitCount;
        });
      }
    } catch (_) {
      // Best-effort refresh: keep the HomePage-provided link (or the
      // fallback share URL) when the request fails.
    }
  }

  OverlayEntry? _activeToast;
}

/// The renderer Flutter draws with in this launch: shader image filters
/// exist under Impeller only.
String _activeRendererName() =>
    ui.ImageFilter.isShaderFilterSupported ? 'Impeller' : 'Skia';

/// The renderer picker of the Developer section.
class _RendererDropdown extends StatelessWidget {
  const _RendererDropdown({required this.value, required this.onChanged});

  final RendererChoice value;
  final ValueChanged<RendererChoice?> onChanged;

  static const _labels = {
    RendererChoice.automatic: 'Automat',
    RendererChoice.skia: 'Skia (stabil)',
    RendererChoice.impeller: 'Impeller',
  };

  @override
  Widget build(BuildContext context) {
    return DropdownButton<RendererChoice>(
      value: value,
      underline: const SizedBox(),
      borderRadius: BorderRadius.circular(12),
      onChanged: onChanged,
      items: [
        for (final MapEntry(key: choice, value: label) in _labels.entries)
          DropdownMenuItem(
            value: choice,
            child: Text(label, style: const TextStyle(fontSize: 14)),
          ),
      ],
    );
  }
}

/// Asks whether to restart now, so the new renderer applies at once.
class _RestartForRendererDialog extends StatelessWidget {
  const _RestartForRendererDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Repornești aplicația?'),
      content: const Text(
        'Noul motor grafic va fi folosit de la următoarea pornire. '
        'Aplicația se închide și se redeschide, iar radioul se oprește.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Mai târziu'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Repornește'),
        ),
      ],
    );
  }
}

/// How many friends opened the user's invitation, with them highlighted in
/// pink like in the share sheet.
class _InviteCountSubtitle extends StatelessWidget {
  const _InviteCountSubtitle({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent =
        isDark ? AppColors.inviteAccent : AppColors.inviteAccentOnLight;
    final (friends, rest) = ShareUtils.visitCountParts(count) ??
        ('', ShareUtils.visitCountText(count));
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.people_outline_rounded, size: 14, color: accent),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: friends,
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(text: rest),
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? const Color(0xff8a8a8a)
                    : const Color(0xff6b6b6b),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The on/off switch of a settings row, in the colors of the rows above.
class _SettingsSwitch extends StatelessWidget {
  const _SettingsSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Switch.adaptive(
      activeThumbColor: Colors.white,
      activeTrackColor:
          isDark ? const Color(0xff48a868) : const Color(0xff34c759),
      inactiveThumbColor: Colors.white,
      inactiveTrackColor:
          isDark ? const Color(0xff39393d) : const Color(0xffe9e9ea),
      value: value,
      onChanged: onChanged,
    );
  }
}
