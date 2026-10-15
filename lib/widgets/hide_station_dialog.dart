import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../types/Station.dart';

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

  static const cancelLabel = 'Anulează';
  static const hideLabel = 'Ascunde';

  @override
  Widget build(BuildContext context) {
    final cupertino = switch (Theme.of(context).platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };
    final car = cupertino ? 'CarPlay' : 'Android Auto';
    return AlertDialog.adaptive(
      title: Text('Ascunzi „${station.displayTitle}”?'),
      content: Text(
        'Stația este la Favorite. Dacă o ascunzi, va fi scoasă din Favorite '
        'și nu va mai apărea în listele de stații, nici în $car.\n\n'
        'O poți readuce oricând din Setări → Stații ascunse.',
      ),
      actions: cupertino
          ? [
              // Bold, as iOS marks the safe choice next to a destructive one.
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.pop(context, false),
                child: const Text(cancelLabel),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(context, true),
                child: const Text(hideLabel),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text(cancelLabel),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text(hideLabel),
              ),
            ],
    );
  }
}
