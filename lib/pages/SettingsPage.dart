import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hy_device_id/hy_device_id.dart';
import 'package:package_info/package_info.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      body: Visibility(
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
                },
                value: _notificationsEnabled ?? true,
              ),
            ),
            Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    'Versiune aplicatie $_version',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
            SizedBox(height: 4.0),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    'Device ID: $_deviceId',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),

            SizedBox(height: 8.0),
          ],
        ),
      )
    );
  }
}
