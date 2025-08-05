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
import 'WriteNfcTag.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          title: Text('Setări'),
        ),
        body: Container(
          margin: const EdgeInsets.only(top: 10),
          child: Visibility(
            visible: _notificationsEnabled != null,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.brightness_6),
                  title: const Text('Interfata temei'),
                  trailing: DropdownButton<ThemeMode>(
                    value: _themeMode,
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
                        child: Text('Sistem'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text('Luminos'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text('Întunecat'),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.radio),
                  title: const Text('Pornește automat ultima stație la deschiderea aplicației'),
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
                ListTile(
                  leading: const Icon(Icons.notification_important_rounded),
                  title: const Text('Notificări personalizate'),
                  subtitle:
                      const Text('Primiți notificări când începe o melodie/emisiune preferată.'),
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
                ListTile(
                  leading: const Icon(Icons.nfc),
                  title: const Text('Inscripționează un tag NFC'),
                  onTap: () => {
                    Navigator.push(context, MaterialPageRoute<void>(
                      builder: (BuildContext context) {
                        return WriteNfcTagPage();
                      },
                    ))
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.share_rounded),
                  title: const Text('Distribuie aplicația'),
                  onTap: () async {
                    await _shareApp(context);
                  },
                ),
                if (kDebugMode) ...[
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.delete_sweep, color: Colors.red),
                    title: const Text('Șterge datele aplicației'),
                    subtitle: const Text('Șterge preferințele și cache-ul (doar în modul debug)'),
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
                                  // Clear shared preferences
                                  final prefs = await SharedPreferences.getInstance();
                                  await prefs.clear();
                                  
                                  // Clear GraphQL cache
                                  final client = GraphQLProvider.of(context).value;
                                  client.cache.store.reset();
                                  
                                  // Show confirmation
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Datele aplicației au fost șterse!'),
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                  
                                  // Refresh the settings page
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
                ],
                const Spacer(),
                ListTile(
                  title: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8.0)),
                      ),
                    ),
                    onPressed: () async {
                      FirebaseCrashlytics.instance.log("WHATSAPP_CONTACT");

                      final message = "Buna ziua [Radio Crestin ${Platform.isAndroid? "Android": Platform.isIOS? "iOS": ""}]\n";
                      launchUrl(
                          Uri.parse(
                              "https://wa.me/40766338046?text=${Uri.encodeFull(message)}"
                          ),
                          mode: LaunchMode.externalApplication);
                    },
                    child: const Text(
                      'Contactează-ne pe WhatsApp',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Text(
                        'Versiune aplicatie $_version ($_buildNumber)',
                        style: const TextStyle(color: Colors.grey, fontSize: 10.0),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          'Device ID: $_deviceId',
                          style: const TextStyle(color: Colors.grey, fontSize: 8.0),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24.0),
              ],
            ),
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
