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

import '../globals.dart' as globals;
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
        final shareUrl = shareLinkData.generateShareUrl();
        final shareMessage = ShareUtils.formatShareMessage(
          shareLinkData: shareLinkData,
          stationName: null,
          stationSlug: null,
        );

        // Show dialog with share options
        ShareHandler.shareApp(
          context: context,
          shareUrl: shareUrl,
          shareMessage: shareMessage,
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
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 24, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildSettingsCard({required List<Widget> children}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xff1e1e1e) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark ? const Color(0xff2a2a2a) : const Color(0xffe0e0e0),
            width: 0.5,
          ),
        ),
        child: Column(
          children: _insertDividers(children),
        ),
      ),
    );
  }

  List<Widget> _insertDividers(List<Widget> children) {
    final result = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      result.add(children[i]);
      if (i < children.length - 1) {
        result.add(Padding(
          padding: const EdgeInsets.only(left: 56),
          child: Divider(height: 1, thickness: 0.5, color: Theme.of(context).dividerColor.withOpacity(0.3)),
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
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
      ),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: subtitle != null
          ? Text(subtitle, style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color))
          : null,
      trailing: trailing,
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          title: const Text('Setări'),
        ),
        body: Visibility(
          visible: _notificationsEnabled != null,
          child: ListView(
            children: [
              // General section
              _buildSectionHeader('General'),
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
                  trailing: Switch(
                    activeColor: Theme.of(context).primaryColor,
                    activeTrackColor: Theme.of(context).primaryColorLight,
                    inactiveThumbColor: Theme.of(context).primaryColorDark,
                    inactiveTrackColor: const Color(0xffdcdcdc),
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
                  trailing: Switch(
                    activeColor: Theme.of(context).primaryColor,
                    activeTrackColor: Theme.of(context).primaryColorLight,
                    inactiveThumbColor: Theme.of(context).primaryColorDark,
                    inactiveTrackColor: const Color(0xffdcdcdc),
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
                _buildSettingsTile(
                  icon: Icons.share_rounded,
                  title: 'Distribuie aplicația',
                  trailing: const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
                  onTap: () async {
                    await _shareApp(context);
                  },
                ),
                _buildSettingsTile(
                  icon: Icons.chat,
                  title: 'Contactează-ne pe WhatsApp',
                  trailing: const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
                  onTap: () async {
                    FirebaseCrashlytics.instance.log("WHATSAPP_CONTACT");

                    final message = "Buna ziua [Radio Crestin ${Platform.isAndroid? "Android": Platform.isIOS? "iOS": ""}]\n";
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
                    trailing: const Icon(Icons.chevron_right, size: 20, color: Colors.red),
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
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Versiune $_version ($_buildNumber)',
                      style: TextStyle(color: Colors.grey.shade500.withValues(alpha: 0.6), fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Device ID: $_deviceId',
                      style: TextStyle(color: Colors.grey.shade500.withValues(alpha: 0.5), fontSize: 10),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
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
