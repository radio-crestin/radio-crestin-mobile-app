import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// SharedPreferences key persisting that the user has acknowledged the one-time
/// "YouTube can't play in the background" warning. Once set, the warning modal
/// never shows again — the persistent on-video chip remains the reminder.
const String youtubeBackgroundWarningAckKey = 'youtube_background_warning_ack';

/// Whether the user has already dismissed the one-time YouTube background
/// warning.
bool youtubeBackgroundWarningAcknowledged(SharedPreferences prefs) =>
    prefs.getBool(youtubeBackgroundWarningAckKey) ?? false;

/// Persists that the user acknowledged the one-time YouTube background warning.
Future<void> acknowledgeYoutubeBackgroundWarning(SharedPreferences prefs) =>
    prefs.setBool(youtubeBackgroundWarningAckKey, true);

/// Pure decision: show the one-time warning iff it has NOT been acknowledged and
/// a YouTube item is currently playing. Top-level so it is trivially testable.
bool shouldShowYoutubeBackgroundWarning({
  required bool acknowledged,
  required bool isYoutubePlaying,
}) =>
    !acknowledged && isYoutubePlaying;

/// Shows the Material 3 acknowledgment dialog explaining that YouTube content
/// cannot play with the screen locked or the app in the background. Awaits
/// [onAcknowledge] (persistence) when the user confirms.
///
/// [barrierDismissible] is false so the single "Am înțeles" button is the only
/// way out — dismissing it IS the acknowledgment.
Future<void> showYoutubeBackgroundWarningDialog(
  BuildContext context, {
  required Future<void> Function() onAcknowledge,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _YoutubeBackgroundWarningDialog(onAcknowledge: onAcknowledge),
  );
}

/// The theme-aware Material 3 warning dialog. Private — callers use
/// [showYoutubeBackgroundWarningDialog].
class _YoutubeBackgroundWarningDialog extends StatelessWidget {
  const _YoutubeBackgroundWarningDialog({required this.onAcknowledge});

  final Future<void> Function() onAcknowledge;

  Future<void> _confirm(BuildContext context) async {
    await onAcknowledge();
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.smart_display_outlined,
          color: AppColors.primary, size: 30),
      title: const Text('Videoclipurile YouTube'),
      content: const Text(
        'Videoclipurile YouTube nu pot fi redate cu ecranul blocat sau cu '
        'aplicația în fundal. Sunetul continuă doar cât timp aplicația rămâne '
        'deschisă pe ecran.',
        style: TextStyle(height: 1.4),
      ),
      actions: [
        FilledButton(
          onPressed: () => _confirm(context),
          child: const Text('Am înțeles'),
        ),
      ],
    );
  }
}
