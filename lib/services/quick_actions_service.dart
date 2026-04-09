import 'dart:io';

import 'package:quick_actions/quick_actions.dart';
import 'analytics_service.dart';
import 'package:url_launcher/url_launcher.dart';

import '../globals.dart' as globals;

class QuickActionsService {
  static const QuickActions _quickActions = QuickActions();

  static void initialize() {
    _quickActions.initialize((String shortcutType) {
      if (shortcutType == 'action_feedback_delete') {
        _openDeleteFeedback();
      } else if (shortcutType == 'action_report_problem') {
        _openReportProblem();
      }
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
      ]);
    }
  }

  static String _buildPlatformInfo() {
    final platform = Platform.isAndroid ? "Android" : Platform.isIOS ? "iOS" : "";
    return "[RadioCrestin/$platform/v${globals.appVersion}/${globals.deviceId}]";
  }

  static Future<void> _openWhatsApp(String message) async {
    final encoded = Uri.encodeFull(message);
    final appUrl = Uri.parse("https://wa.me/40766338046?text=$encoded");

    final launched = await launchUrl(appUrl, mode: LaunchMode.externalApplication);
    if (!launched) {
      // Fallback: open WhatsApp Web in browser
      await launchUrl(appUrl, mode: LaunchMode.inAppBrowserView);
    }
  }

  static Future<void> _openDeleteFeedback() async {
    AnalyticsService.instance.capture('quick_action_feedback_delete');
    final info = _buildPlatformInfo();
    await _openWhatsApp("$info\n\nBuna ziua,\n\nAs dori sa va ofer feedback despre aplicatie:\n");
  }

  static Future<void> _openReportProblem() async {
    AnalyticsService.instance.capture('quick_action_report_problem');
    final info = _buildPlatformInfo();
    await _openWhatsApp("$info\n\nBuna ziua,\n\nAs dori sa raportez urmatoarea problema:\n");
  }
}
