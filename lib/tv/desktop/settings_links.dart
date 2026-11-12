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

/// The website's contact page, or one of its forms ([path], e.g.
/// `/contact/problema/`). The app's details travel along so the message
/// arrives tagged with the platform, version and device it came from.
Uri contactPageUri({
  required String platform,
  required String appVersion,
  required String deviceId,
  String path = '/contact/',
}) =>
    Uri.https('www.radiocrestin.ro', path, {
      'source': 'app',
      'platform': platform,
      'app_version': appVersion,
      if (deviceId.isNotEmpty) 'device_id': deviceId,
    });
