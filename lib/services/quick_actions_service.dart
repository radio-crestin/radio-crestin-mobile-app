import 'dart:developer' as developer;
import 'dart:io';

import 'package:quick_actions/quick_actions.dart';
import 'analytics_service.dart';
import 'package:url_launcher/url_launcher.dart';

import '../globals.dart' as globals;
import '../tv/desktop/settings_links.dart';

class QuickActionsService {
  static const QuickActions _quickActions = QuickActions();

  static void initialize() {
    // Home screen shortcuts exist only on iOS and Android: on macOS, Windows
    // and Linux the plugin has no implementation, and every call would fail
    // with a MissingPluginException.
    if (!Platform.isIOS && !Platform.isAndroid) return;
    // initialize() resolves getLaunchAction internally, which throws on Android
    // when there's no foreground Activity (background launch / secondary engine)
    // or the plugin isn't attached. Catch it at the source so it never escapes
    // as an unhandled async error. (PostHog 019d73e1…, 019d8e4e…)
    _quickActions.initialize((String shortcutType) {
      if (shortcutType == 'action_feedback_delete') {
        _openDeleteFeedback();
      } else if (shortcutType == 'action_report_problem') {
        _openReportProblem();
      }
    }).catchError((Object e) {
      developer.log('quick_actions initialize failed: $e');
    });

    if (Platform.isAndroid) {
      _quickActions.setShortcutItems([
        const ShortcutItem(
          type: 'action_feedback_delete',
          localizedTitle: 'Înainte să pleci... 🥺',
          localizedSubtitle: 'Ajută-ne să facem aplicația mai bună...',
          icon: 'ic_quick_action_feedback',
        ),
        const ShortcutItem(
          type: 'action_report_problem',
          localizedTitle: 'Raporteaza o problema',
          localizedSubtitle: 'Spune-ne ce nu a mers.',
          icon: 'ic_quick_action_report',
        ),
      ]).catchError((Object e) {
        developer.log('quick_actions setShortcutItems failed: $e');
      });
    }
  }

  /// Opens one of the website's contact forms, tagged with this app's details;
  /// [type] picks what a suggestion is about ("bug" for a problem).
  static Future<void> _openContactForm(String path, {String? type}) async {
    final base = contactPageUri(
      platform: Platform.isAndroid ? 'android' : 'ios',
      appVersion: globals.appVersion,
      deviceId: globals.deviceId,
      path: path,
    );
    final uri = type == null ? base : base.replace(queryParameters: {...base.queryParameters, 'type': type});
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
  }

  static Future<void> _openDeleteFeedback() async {
    AnalyticsService.instance.capture('quick_action_feedback_delete');
    await _openContactForm('/contact/sugestie/');
  }

  static Future<void> _openReportProblem() async {
    AnalyticsService.instance.capture('quick_action_report_problem');
    await _openContactForm('/contact/sugestie/', type: 'bug');
  }
}
