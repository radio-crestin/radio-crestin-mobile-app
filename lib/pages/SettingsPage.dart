import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/widgets/share_handler.dart';
import 'package:radio_crestin/utils/share_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../appAudioHandler.dart';
import '../globals.dart' as globals;
import '../main.dart' show getIt;
import '../services/analytics_service.dart';
import '../seek_mode_manager.dart';
import '../theme.dart';
import '../theme_manager.dart';
import '../widgets/bottom_toast.dart';


class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.shareLinkData});

  final ShareLinkData? shareLinkData;

  static void show(BuildContext context, {ShareLinkData? shareLinkData}) {
    Navigator.push(context, PageRouteBuilder<void>(
      pageBuilder: (context, animation, secondaryAnimation) =>
          SettingsPage(shareLinkData: shareLinkData),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ));
  }

  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _notificationsEnabled;
  bool? _autoStartStation;
  ThemeMode _themeMode = ThemeMode.system;
  SeekMode _seekMode = SeekMode.twoMinutes;
  bool _unstableConnection = false;
  bool _carConnected = SeekModeManager.isCarConnected;
  final String _version = globals.appVersion;
  final String _buildNumber = globals.buildNumber;
  final String _deviceId = globals.deviceId;
  ShareLinkData? _shareLinkData;
  int? _visitCount;
  bool _isLoadingShareData = true;


  @override
  void initState() {
    super.initState();
    _getNotificationsEnabled();
    _getAutoStartStation();
    _loadThemeMode();
    _loadSeekMode();
    _loadUnstableConnection();
    SeekModeManager.carConnected.addListener(_onCarConnectionChanged);
    if (widget.shareLinkData != null) {
      _shareLinkData = widget.shareLinkData;
      _visitCount = widget.shareLinkData!.visitCount;
      _isLoadingShareData = false;
    }
    _loadShareData();
  }

  @override
  void dispose() {
    SeekModeManager.carConnected.removeListener(_onCarConnectionChanged);
    super.dispose();
  }

  void _onCarConnectionChanged() {
    if (mounted) {
      setState(() {
        _carConnected = SeekModeManager.isCarConnected;
      });
    }
  }

  Future<void> _getNotificationsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _notificationsEnabled = prefs.getBool('_notificationsEnabled') ?? true;
    });
  }

  Future<void> _getAutoStartStation() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoStartStation = prefs.getBool('_autoStartStation') ?? true;
    });
  }


  void _shareApp(BuildContext context) {
    final fallbackUrl = 'https://www.radiocrestin.ro/descarca-aplicatia-radio-crestin';
    ShareHandler.shareApp(
      context: context,
      shareUrl: _shareLinkData?.generateShareUrl() ?? fallbackUrl,
      shareMessage: 'Instalează și tu aplicația Radio Creștin și ascultă peste 60 de stații de radio creștin:\n$fallbackUrl',
      shareLinkData: _shareLinkData,
      showDialog: true,
      shareLinkLoader: _shareLinkData == null
          ? () async {
              final prefs = await SharedPreferences.getInstance();
              final deviceId = prefs.getString('device_id');
              if (deviceId == null) return null;
              final audioHandler = getIt<AppAudioHandler>();
              final shareService = ShareService(audioHandler.graphqlClient);
              return shareService.getShareLink(deviceId);
            }
          : null,
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
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xff1c1c1e) : const Color(0xfff2f2f7),
          borderRadius: BorderRadius.circular(16),
        ),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        centerTitle: true,
        title: Text(
          'Setări',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
      ),
      body: Visibility(
        visible: _notificationsEnabled != null,
        child: ListView(
          children: [
                // General section
                _buildSectionHeader('Preferințe'),
                _buildSettingsCard(children: [
                  _buildSettingsTile(
                    icon: Icons.brightness_6,
                    title: 'Interfața temei',
                    trailing: DropdownButton<ThemeMode>(
                      value: _themeMode,
                      underline: const SizedBox(),
                      borderRadius: BorderRadius.circular(12),
                      onChanged: (ThemeMode? newValue) async {
                        if (newValue != null) {
                          AnalyticsService.instance.capture('button_clicked', {'button_name': 'theme_mode', 'theme_mode': newValue.name});
                          setState(() {
                            _themeMode = newValue;
                          });
                          await ThemeManager.saveThemeMode(newValue);
                          ThemeManager.changeThemeMode(newValue);
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
                            setState(() {
                              _unstableConnection = value;
                              if (value) {
                                _seekMode = SeekMode.fiveMinutes;
                              }
                            });
                            await SeekModeManager.saveUnstableConnection(value);
                            SeekModeManager.changeUnstableConnection(value);
                            if (value) {
                              await SeekModeManager.saveSeekMode(SeekMode.fiveMinutes);
                              SeekModeManager.changeSeekMode(SeekMode.fiveMinutes);
                            }
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
                          onChanged: (SeekMode? newValue) async {
                            if (newValue != null) {
                              AnalyticsService.instance.capture('button_clicked', {'button_name': 'buffer_size', 'seek_mode': newValue.name});
                              setState(() {
                                _seekMode = newValue;
                              });
                              await SeekModeManager.saveSeekMode(newValue);
                              SeekModeManager.changeSeekMode(newValue);
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
                      onChanged: (bool? value) async {
                        AnalyticsService.instance.capture('button_clicked', {'button_name': 'auto_start_station', 'enabled': value});
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool('_autoStartStation', value!);
                        setState(() {
                          _autoStartStation = value;
                        });
                      },
                      value: _autoStartStation ?? true,
                    ),
                  ),
                  _buildSettingsTile(
                    icon: Icons.notification_important_rounded,
                    title: 'Notificări personalizate',
                    subtitle: 'Primiți notificări când începe o melodie/emisiune preferată.',
                    trailing: Switch.adaptive(
                      activeColor: Colors.white,
                      activeTrackColor: isDark ? const Color(0xff48a868) : const Color(0xff34c759),
                      inactiveThumbColor: Colors.white,
                      inactiveTrackColor: isDark ? const Color(0xff39393d) : const Color(0xffe9e9ea),
                      onChanged: (bool? value) async {
                        AnalyticsService.instance.capture('button_clicked', {'button_name': 'custom_notifications', 'enabled': value});
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool('_notificationsEnabled', value!);
                        setState(() {
                          _notificationsEnabled = value;
                        });
                        AnalyticsService.instance.setUserProperty('personalized_n', value ? 'true' : 'false');
                      },
                      value: _notificationsEnabled ?? true,
                    ),
                  ),
                ]),

                _buildSectionHeader('General'),
                _buildSettingsCard(children: [
                  _buildSettingsTile(
                    icon: Icons.share_rounded,
                    title: 'Distribuie aplicația',
                    subtitleWidget: _visitCount != null && _visitCount! > 0
                        ? Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Icon(
                                    Icons.people_outline_rounded,
                                    size: 14,
                                    color: isDark ? const Color(0xFFffc700) : const Color(0xFFFF6B35),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    '${_formatVisitCount(_visitCount!)} persoane au deschis aplicația prin linkul tău',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: isDark ? const Color(0xFFffc700) : const Color(0xFFFF6B35),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Text(
                            'Trimite linkul tău prietenilor și familiei',
                            style: TextStyle(fontSize: 12, color: isDark ? const Color(0xff8a8a8a) : const Color(0xff6b6b6b)),
                          ),
                    onTap: () {
                      AnalyticsService.instance.capture('button_clicked', {'button_name': 'share_app'});
                      _shareApp(context);
                    },
                  ),
                  _buildSettingsTile(
                    icon: Icons.star_rounded,
                    title: 'Lasă-ne o recenzie',
                    onTap: () async {
                      AnalyticsService.instance.capture('button_clicked', {'button_name': 'leave_review'});
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

                      final platform = Platform.isAndroid ? "Android" : Platform.isIOS ? "iOS" : "";
                      final message = "[RadioCrestin/$platform/v${globals.appVersion}/${globals.deviceId}]\n\nBuna ziua,\n";
                      launchUrl(
                          Uri.parse(
                              "https://wa.me/40766338046?text=${Uri.encodeFull(message)}"
                          ),
                          mode: LaunchMode.externalApplication);
                    },
                  ),
                ]),

                if (kDebugMode) ...[
                  _buildSectionHeader('Debug'),
                  _buildSettingsCard(children: [
                    _buildSettingsTile(
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

                                    setState(() {
                                      _notificationsEnabled = null;
                                      _autoStartStation = null;
                                    });
                                    _getNotificationsEnabled();
                                    _getAutoStartStation();
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
                const SizedBox(height: 32),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Versiune $_version ($_buildNumber)',
                        style: TextStyle(color: isDark ? const Color(0xff5a5a5c) : const Color(0xff8e8e93), fontSize: 12),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Device ID: $_deviceId',
                        style: TextStyle(color: isDark ? const Color(0xff48484a) : const Color(0xffaeaeb2), fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
            ],
          ),
        ),
    );
  }

  Future<void> _loadThemeMode() async {
    final themeMode = await ThemeManager.loadThemeMode();
    setState(() {
      _themeMode = themeMode;
    });
  }

  Future<void> _loadSeekMode() async {
    final seekMode = await SeekModeManager.loadSeekMode();
    setState(() {
      _seekMode = seekMode;
    });
  }

  Future<void> _loadShareData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? deviceId = prefs.getString('device_id');

      if (deviceId == null) {
        final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          deviceId = androidInfo.id;
        } else if (Platform.isIOS) {
          final iosInfo = await deviceInfo.iosInfo;
          deviceId = iosInfo.identifierForVendor;
        } else {
          deviceId = DateTime.now().millisecondsSinceEpoch.toString();
        }
        if (deviceId != null) {
          await prefs.setString('device_id', deviceId);
        }
      }

      final audioHandler = getIt<AppAudioHandler>();
      final shareService = ShareService(audioHandler.graphqlClient);
      final data = await shareService.getShareLink(deviceId!);

      if (mounted && data != null) {
        setState(() {
          _shareLinkData = data;
          _visitCount = data.visitCount;
          _isLoadingShareData = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingShareData = false);
      }
    }
  }

  String _formatVisitCount(int count) {
    if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(count % 1000000 == 0 ? 0 : 1)}M';
    } else if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(count % 1000 == 0 ? 0 : 1)}k';
    }
    return count.toString();
  }

  Future<void> _loadUnstableConnection() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _unstableConnection = prefs.getBool('unstable_connection') ?? false;
    });
  }

  OverlayEntry? _activeToast;
}
