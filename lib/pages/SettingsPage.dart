import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../globals.dart' as globals;
import 'WriteNfcTag.dart';

class SettingsPage extends StatefulWidget {
  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _notificationsEnabled = null;
  String _version = globals.appVersion;
  String _deviceId = globals.deviceId;

  @override
  void initState() {
    super.initState();
    _getNotificationsEnabled();
  }

  Future<void> _getNotificationsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _notificationsEnabled = prefs.getBool('_notificationsEnabled') ?? true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: Text('Setari'),
        ),
        body: Container(
          margin: const EdgeInsets.only(top: 10),
          child: Visibility(
            visible: _notificationsEnabled != null,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.notification_important_rounded),
                  title: Text('Notificari personalizate'),
                  subtitle: Text('Primiti notificari cand incepe o melodie/emisiune preferata.'),
                  trailing: Switch(
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
                  title: const Text('Inscripționează o etichetă NFC'),
                  onTap: () => {
                  Navigator.push(context, MaterialPageRoute<void>(
                    builder: (BuildContext context) {
                      return WriteNfcTagPage();
                    },
                  ))
                },
                ),
                Spacer(),
                ListTile(
                  title: ElevatedButton(
                    onPressed: () async {
                      final event = SentryEvent(
                        message: SentryMessage("WHATSAPP_CONTACT"),
                        level: SentryLevel.debug
                            
                      );

                      Sentry.captureEvent(event);
                      
                      // https://pub.dev/packages/url_launcher
                      // TODO: we might need to add some additional details for iOS
                      launchUrl(Uri.parse("https://wa.me/40773994595?text=Buna%20ziua%20%5BRadio%20Crestin%5D"),
                          mode: LaunchMode.externalApplication);
                    },
                    child: Text('Contactează-ne pe WhatsApp'),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Text(
                        'Versiune aplicatie $_version',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4.0),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Text(
                        'Device ID: $_deviceId',
                        style: const TextStyle(color: Colors.grey),
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
}
