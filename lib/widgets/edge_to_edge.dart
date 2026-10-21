import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Lays the app out behind Android's navigation bar, the way iOS lays it
/// out behind the home indicator.
///
/// Android 15 and later do this on their own. Before them the bar was a
/// black band under the app, which reported no bottom inset, so the bottom
/// sheets' last row sat right on top of it. Flutter can switch it on from
/// Android 10 (API 29); on Android 8 and 9 the bar stays as it was.
abstract final class EdgeToEdge {
  static bool _enabled = false;

  /// Whether the app is drawn behind the navigation bar.
  static bool get enabled => _enabled;

  /// Switches it on. Call once, before `runApp`.
  static Future<void> enable() async {
    if (!Platform.isAndroid) return;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt < 29) return;
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      _enabled = true;
    } catch (e) {
      debugPrint('Edge-to-edge setup failed: $e');
    }
  }
}

/// Keeps the navigation bar see-through over the app once [EdgeToEdge] is
/// on, with buttons that read on the theme's background.
///
/// Every surface that reaches the bottom of the screen follows the theme:
/// the pages, the strip under the mini player, the player's backdrop and
/// the bottom sheets. So one style for the whole app is enough, and no
/// system scrim is needed to keep the buttons visible.
class EdgeToEdgeNavigationBar extends StatelessWidget {
  const EdgeToEdgeNavigationBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!EdgeToEdge.enabled) return child;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness:
            isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: child,
    );
  }
}
