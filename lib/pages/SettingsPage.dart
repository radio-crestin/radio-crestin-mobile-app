import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hy_device_id/hy_device_id.dart';
import 'package:package_info/package_info.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsPage extends StatefulWidget {
  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _notificationsEnabled = null;
  String _version = '';
  String _deviceId = '';
  final _hyDeviceIdPlugin = HyDeviceId();

  @override
  void initState() {
    super.initState();
    _getNotificationsEnabled();
    _getAppVersion();
    _getClientId();
  }

  Future<void> _getNotificationsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _notificationsEnabled = prefs.getBool('_notificationsEnabled') ?? true;
    });
  }

  Future<void> _getClientId() async {
    var deviceId = '';
    try {
      deviceId = await _hyDeviceIdPlugin.getDeviceId() ?? 'Unknown device Id';
    } on PlatformException {
      deviceId = 'Failed to get device Id.';
    }
    setState(() {
      _deviceId = deviceId;
    });
  }

  Future<void> _getAppVersion() async {
    final PackageInfo packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      _version = packageInfo.version;
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
                Spacer(),
                ListTile(
                  title: RichText(
                    text: TextSpan(
                      text: 'Pentru sugestii va rugam sa ne contactati pe ',
                      style: TextStyle(color: Colors.black),
                      children: [
                        TextSpan(
                          text: 'WhatsApp',
                          style: const TextStyle(
                            decoration: TextDecoration.underline,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () {
                              // https://pub.dev/packages/url_launcher
                              // TODO: we might need to add some additional details for iOS
                              launchUrl(Uri.parse("https://wa.me/40773994595?text=Buna%20ziua"),
                                  mode: LaunchMode.externalApplication);
                            },
                        ),
                        const TextSpan(
                          text: '.',
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Text(
                        'Versiune aplicatie $_version',
                        style: TextStyle(color: Colors.grey),
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
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 24.0),
              ],
            ),
          ),
        ));
  }
}
