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

  @visibleForTesting
  static set enabledForTesting(bool value) => _enabled = value;

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
///
/// The status bar takes the app bar's style, as every page header does, so
/// changing pages never changes the style. Each change relaid out the
/// window on Android 10 and earlier, ~40 ms on the main thread (moto g7
/// plus), which also draws Flutter's frames.
class EdgeToEdgeNavigationBar extends StatelessWidget {
  const EdgeToEdgeNavigationBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!EdgeToEdge.enabled) return child;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final statusBar =
        theme.appBarTheme.systemOverlayStyle ?? const SystemUiOverlayStyle();
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: statusBar.copyWith(
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
