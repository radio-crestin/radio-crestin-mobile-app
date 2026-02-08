import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/widgets/share_handler.dart';
import 'package:radio_crestin/utils/share_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../appAudioHandler.dart';
import '../globals.dart' as globals;
import '../main.dart' show getIt;
import '../theme_manager.dart';


class SettingsPage extends StatefulWidget {
  const SettingsPage({Key? key}) : super(key: key);

  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _notificationsEnabled;
  bool? _autoStartStation;
  ThemeMode _themeMode = ThemeMode.system;
  final String _version = globals.appVersion;
  final String _buildNumber = globals.buildNumber;
  final String _deviceId = globals.deviceId;


  @override
  void initState() {
    super.initState();
    _getNotificationsEnabled();
    _getAutoStartStation();
    _loadThemeMode();
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


  Future<void> _shareApp(BuildContext context) async {
    try {
      // Get device ID
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

      // Get GraphQL client
      final client = GraphQLProvider.of(context).value;
      final shareService = ShareService(client);
      final shareLinkData = await shareService.getShareLink(deviceId!);

      if (shareLinkData != null) {
        final currentStation = getIt<AppAudioHandler>().currentStation.valueOrNull;
        final shareUrl = shareLinkData.generateShareUrl(
          stationSlug: currentStation?.slug,
        );
        final shareMessage = ShareUtils.formatShareMessage(
          shareLinkData: shareLinkData,
          stationName: currentStation?.title,
          stationSlug: currentStation?.slug,
        );

        // Show dialog with share options
        ShareHandler.shareApp(
          context: context,
          shareUrl: shareUrl,
          shareMessage: shareMessage,
          stationName: currentStation?.title,
          shareLinkData: shareLinkData,
          showDialog: true,
        );
      }
    } catch (e) {
      // Fallback to old method if something fails
      ShareHandler.shareApp(
        context: context,
        shareUrl: 'https://asculta.radiocrestin.ro',
        shareMessage: 'Aplicația Radio Creștin:\nhttps://asculta.radiocrestin.ro',
        showDialog: false, // Direct share for fallback
      );
    }
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xff1c1c1e) : const Color(0xfff2f2f7),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: _insertDividers(children),
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
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
      subtitle: subtitle != null
          ? Text(subtitle, style: TextStyle(fontSize: 12, color: isDark ? const Color(0xff8a8a8a) : const Color(0xff6b6b6b)))
          : null,
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
          leading: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: Icon(
                Icons.arrow_back_ios_new,
                size: 20,
                color: isDark ? const Color(0xffb0b0b0) : const Color(0xff3a3a3c),
              ),
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
                  icon: Icons.radio,
                  title: 'Pornește automat ultima stație',
                  subtitle: 'La deschiderea aplicației',
                  trailing: Switch.adaptive(
                    activeColor: Colors.white,
                    activeTrackColor: isDark ? const Color(0xff48a868) : const Color(0xff34c759),
                    inactiveThumbColor: Colors.white,
                    inactiveTrackColor: isDark ? const Color(0xff39393d) : const Color(0xffe9e9ea),
                    onChanged: (bool? value) async {
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
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('_notificationsEnabled', value!);
                      setState(() {
                        _notificationsEnabled = value;
                      });
                      await FirebaseAnalytics.instance
                          .setUserProperty(name: 'personalized_n', value: value ? 'true' : 'false');
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
                  onTap: () async {
                    await _shareApp(context);
                  },
                ),
                _buildSettingsTile(
                  icon: Icons.star_rounded,
                  title: 'Lasă-ne o recenzie',
                  onTap: () async {
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
                    FirebaseCrashlytics.instance.log("WHATSAPP_CONTACT");

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

                                  final client = GraphQLProvider.of(context).value;
                                  client.cache.store.reset();

                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Datele aplicației au fost șterse!'),
                                      duration: Duration(seconds: 2),
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
        ));
  }

  Future<void> _loadThemeMode() async {
    final themeMode = await ThemeManager.loadThemeMode();
    setState(() {
      _themeMode = themeMode;
    });
  }
}
