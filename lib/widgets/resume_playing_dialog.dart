import 'package:flutter/cupertino.dart';

/// Three-way answer the user can give to the iOS resume-playback prompt.
enum ResumePlayingChoice {
  /// Play the last station now.
  play,

  /// Don't play now — just show the app.
  dontPlay,

  /// Don't ask again. The autoplay setting becomes locked off until the
  /// user explicitly resets it from Settings.
  dontAskAgain,
}

/// iOS-style alert that asks whether to resume the previously played
/// station. Returns `null` only if the dialog is dismissed in some
/// non-tap way (rare on iOS where alerts are modal); callers should
/// treat `null` as "don't play, don't change anything".
Future<ResumePlayingChoice?> showResumePlayingDialog(
  BuildContext context, {
  required String stationName,
}) {
  return showCupertinoDialog<ResumePlayingChoice>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return CupertinoAlertDialog(
        title: const Text('Reluăm redarea?'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Vrei să redăm „$stationName"?',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        actions: <CupertinoDialogAction>[
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () =>
                Navigator.of(dialogContext).pop(ResumePlayingChoice.play),
            child: const Text('Da, redă'),
          ),
          CupertinoDialogAction(
            onPressed: () =>
                Navigator.of(dialogContext).pop(ResumePlayingChoice.dontPlay),
            child: const Text('Nu acum'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext)
                .pop(ResumePlayingChoice.dontAskAgain),
            child: const Text('Nu mă mai întreba'),
          ),
        ],
      );
    },
  );
}
