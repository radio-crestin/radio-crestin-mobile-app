import 'package:flutter/material.dart';

import '../theme.dart';

/// "+ Readaugă", a pill that puts a hidden station back in the lists: the
/// plus for adding, as "Afișează" alone said nothing of where to.
///
/// Dark: the neutral capsule of the player's sheets (sleep timer, share),
/// white on white at 13%, so the logos stay the colorful part of the row.
/// Light: pink on a tint of it, faint enough for the text to keep 4.5:1
/// contrast, unless [fill] gives the pill its own color.
class ReAddStationButton extends StatelessWidget {
  const ReAddStationButton({super.key, required this.onPressed, this.fill});

  final VoidCallback onPressed;

  /// The pill's color in the light theme, for a pill on a grey card.
  final Color? fill;

  static const String label = 'Readaugă';

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = dark ? AppColors.darkText : AppColors.groupedActionOnLight;
    final background = dark
        ? AppColors.darkText.withValues(alpha: 0.13)
        : fill ?? AppColors.groupedActionOnLight.withValues(alpha: 0.08);
    return TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text(label),
      style: TextButton.styleFrom(
        foregroundColor: text,
        backgroundColor: background,
        shape: const StadiumBorder(),
        minimumSize: const Size(0, 34),
        padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 14, 0),
        // The pill is 34 high, its touch area the full 48.
        tapTargetSize: MaterialTapTargetSize.padded,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }
}
