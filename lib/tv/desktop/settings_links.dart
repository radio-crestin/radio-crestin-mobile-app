import 'package:url_launcher/url_launcher.dart';

/// The app's id in the App Store, the same app on iPhone, iPad and Mac.
const String appStoreId = '6451270471';

/// The app's review page in the Mac App Store app.
final Uri macAppStoreReviewUri = Uri.parse(
    'macappstore://apps.apple.com/app/id$appStoreId?action=write-review');

/// The same review page on the web, for when the App Store app can't be
/// opened.
final Uri appStoreReviewWebUri =
    Uri.parse('https://apps.apple.com/app/id$appStoreId?action=write-review');

/// Opens the app's review page in the Mac App Store, or on the web when the
/// App Store app doesn't take the link.
///
/// [launch] stands in for `launchUrl` in tests.
Future<void> openMacAppStoreReview({
  Future<bool> Function(Uri url, {LaunchMode mode})? launch,
}) async {
  final open = launch ?? _launchExternally;
  for (final url in [macAppStoreReviewUri, appStoreReviewWebUri]) {
    try {
      if (await open(url, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Try the next link.
    }
  }
}

/// The app's page in the Mac App Store app, where an update installs.
final Uri macAppStorePageUri =
    Uri.parse('macappstore://apps.apple.com/app/id$appStoreId');

/// The same page on the web.
final Uri appStorePageWebUri =
    Uri.parse('https://apps.apple.com/app/id$appStoreId');

/// Opens the app's page in the Mac App Store, or on the web when the App
/// Store app doesn't take the link.
///
/// [launch] stands in for `launchUrl` in tests.
Future<void> openMacAppStorePage({
  Future<bool> Function(Uri url, {LaunchMode mode})? launch,
}) async {
  final open = launch ?? _launchExternally;
  for (final url in [macAppStorePageUri, appStorePageWebUri]) {
    try {
      if (await open(url, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Try the next link.
    }
  }
}

Future<bool> _launchExternally(Uri url,
        {LaunchMode mode = LaunchMode.platformDefault}) =>
    launchUrl(url, mode: mode);

/// The desktop system as support messages name it ("macOS"), from
/// `Platform.operatingSystem`; empty for the phones, which name themselves.
String desktopPlatformLabel(String operatingSystem) =>
    switch (operatingSystem) {
      'macos' => 'macOS',
      'windows' => 'Windows',
      'linux' => 'Linux',
      _ => '',
    };
