import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../globals.dart' as globals;
import '../theme_manager.dart';
import 'WriteNfcTag.dart';

final remoteConfig = FirebaseRemoteConfig.instance;

class SettingsPage extends StatefulWidget {
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
                  title: const Text('Trimite aplicația'),
                  onTap: () {
                    Share.share(remoteConfig.getString("share_app_message"));
                  },
                ),
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
