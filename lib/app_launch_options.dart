import 'services/network_service.dart';

/// How a launch of the app reaches the outside world.
///
/// The store build launches with the defaults. The e2e tests
/// (`integration_test/`) point every request at their local fake radio
/// server and keep their runs out of PostHog, the stores and push.
class AppLaunchOptions {
  const AppLaunchOptions({
    this.apiBaseUrl,
    this.internetProbes,
    this.liveOriginHosts,
    this.reportsAnalytics = true,
    this.registersForPush = true,
    this.promptsForUpdates = true,
  });

  /// Replaces `CONSTANTS.API_BASE_URL`, which every API URL derives from.
  final String? apiBaseUrl;

  /// Replaces the endpoints that tell whether the internet answers.
  final List<InternetProbe>? internetProbes;

  /// Replaces the hosts of the live HLS origin, whose streams start from
  /// their 2- and 5-minute variants and play through iOS's hold proxy.
  final Set<String>? liveOriginHosts;

  /// Whether PostHog receives events, logs and errors.
  final bool reportsAnalytics;

  /// Whether the app asks for push permission and an FCM token.
  final bool registersForPush;

  /// Whether the app checks the store for a newer version and offers it.
  final bool promptsForUpdates;
}
