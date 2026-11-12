import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Stands in for the system's link opener: records what the app asks to
/// open, and how, instead of leaving the app.
class RecordingLauncher extends UrlLauncherPlatform {
  /// Each request: the URL and how the app wanted it opened.
  final List<({String url, PreferredLaunchMode mode})> launches = [];

  /// Whether an app (such as YouTube) takes links opened only in apps;
  /// false is a phone without it.
  bool appInstalled = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launches.add((url: url, mode: options.mode));
    return options.mode != PreferredLaunchMode.externalNonBrowserApplication ||
        appInstalled;
  }
}
