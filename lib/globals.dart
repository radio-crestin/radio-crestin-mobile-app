library my_prj.globals;

import 'package:flutter/material.dart';
import 'stores/app_settings_store.dart';

String fcmToken = "";
String deviceId = "";
String appVersion = "";
String buildNumber = "";
AppStore? appStore;

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
