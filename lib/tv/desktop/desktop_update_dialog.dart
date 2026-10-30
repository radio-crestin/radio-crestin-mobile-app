import 'package:flutter/material.dart';

import '../../services/mac_app_store_updates.dart';
import '../tv_theme.dart';
import 'now_playing_controls.dart';

/// Offers [release], newer than [currentVersion], in a dialog; says whether
/// the listener chose to update ("Actualizează") rather than put it off
/// ("Mai târziu", Esc or a click outside).
Future<bool> showDesktopUpdateDialog(
  BuildContext context, {
  required MacAppStoreRelease release,
  required String currentVersion,
}) async {
  final update = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    // Named so PostHog records a `$screen` for it.
    routeSettings: const RouteSettings(name: '/update'),
    builder: (_) => DesktopUpdateDialog(
      release: release,
      currentVersion: currentVersion,
    ),
  );
  return update ?? false;
}

/// "Versiune nouă disponibilă": the app's icon, the new version and the
/// one running, what's new in it as written for the store, and the choice
/// to update now or later. Return updates.
class DesktopUpdateDialog extends StatelessWidget {
  const DesktopUpdateDialog({
    super.key,
    required this.release,
    required this.currentVersion,
  });

  final MacAppStoreRelease release;
  final String currentVersion;

  static const String title = 'Versiune nouă disponibilă';
  static const String laterLabel = 'Mai târziu';
  static const String updateLabel = 'Actualizează';

  @override
  Widget build(BuildContext context) {
    final notes = release.releaseNotes;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: NowPlayingPalette.panel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: NowPlayingPalette.edge),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset(
                    'assets/icons/ic_logo_filled.png',
                    width: 64,
                    height: 64,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: TvColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Radio Creștin ${release.version} e în Mac App Store. '
                  'Tu ai versiunea $currentVersion.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: TvColors.textSecondary,
                  ),
                ),
                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _ReleaseNotes(notes: notes),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: TvColors.textPrimary,
                          side: const BorderSide(color: NowPlayingPalette.edge),
                          minimumSize: const Size.fromHeight(44),
                          shape: const StadiumBorder(),
                        ),
                        child: const Text(laterLabel),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        autofocus: true,
                        onPressed: () => Navigator.of(context).pop(true),
                        style: FilledButton.styleFrom(
                          backgroundColor: TvColors.primary,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(44),
                          shape: const StadiumBorder(),
                          textStyle: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        child: const Text(updateLabel),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Ce e nou": the store's notes for the version, scrolling when long.
class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes({required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: NowPlayingPalette.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Ce e nou',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: TvColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              child: Text(
                notes,
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: TvColors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
