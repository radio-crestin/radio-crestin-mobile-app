import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../types/Station.dart';

/// What the question before hiding a favorite says, on the phone and in
/// the desktop's own dialog, so the two never drift apart.
class HideFavoriteWording {
  HideFavoriteWording._();

  static const cancelLabel = 'Anulează';
  static const hideLabel = 'Ascunde';

  static String title(Station station) =>
      'Ascunzi „${station.displayTitle}”?';

  /// Why hiding a favorite is asked first. [carScreen] names the car
  /// screen the station also leaves ("CarPlay", "Android Auto"); a
  /// computer has none to mention.
  static String message({String? carScreen}) =>
      'Stația este la Favorite. Dacă o ascunzi, va fi scoasă din Favorite '
      'și nu va mai apărea în listele de stații'
      '${carScreen == null ? '' : ', nici în $carScreen'}.\n\n'
      'O poți readuce oricând din Setări → Stații ascunse.';
}

/// Asks before hiding [station], a favorite: hiding it also takes it out of
/// the favorites. The platform's own alert, with "Ascunde" as the
/// destructive action. Resolves to whether the listener confirmed.
Future<bool> confirmHideFavoriteStation(
  BuildContext context,
  Station station,
) async {
  final confirmed = await showAdaptiveDialog<bool>(
    context: context,
    builder: (context) => _HideFavoriteDialog(station: station),
  );
  return confirmed ?? false;
}

class _HideFavoriteDialog extends StatelessWidget {
  const _HideFavoriteDialog({required this.station});

  final Station station;

  @override
  Widget build(BuildContext context) {
    final cupertino = switch (Theme.of(context).platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };
    return AlertDialog.adaptive(
      title: Text(HideFavoriteWording.title(station)),
      content: Text(
        HideFavoriteWording.message(
          carScreen: cupertino ? 'CarPlay' : 'Android Auto',
        ),
      ),
      actions: cupertino
          ? [
              // Bold, as iOS marks the safe choice next to a destructive one.
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.pop(context, false),
                child: const Text(HideFavoriteWording.cancelLabel),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(context, true),
                child: const Text(HideFavoriteWording.hideLabel),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text(HideFavoriteWording.cancelLabel),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text(HideFavoriteWording.hideLabel),
              ),
            ],
    );
  }
}
