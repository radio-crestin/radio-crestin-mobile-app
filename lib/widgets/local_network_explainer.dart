import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// SharedPreferences key persisting that the user accepted the one-time
/// local-network explainer shown before iOS raises its system prompt.
const String localNetworkExplainerAckKey = 'local_network_explainer_ack';

/// Whether the user already accepted the local-network explainer.
bool localNetworkExplainerAcknowledged(SharedPreferences prefs) =>
    prefs.getBool(localNetworkExplainerAckKey) ?? false;

/// Persists that the user accepted the local-network explainer.
Future<void> acknowledgeLocalNetworkExplainer(SharedPreferences prefs) =>
    prefs.setBool(localNetworkExplainerAckKey, true);

/// Gates Cast device discovery behind a one-time, in-app explanation.
///
/// Discovery is what makes iOS raise its "Local Network" prompt, and that
/// system dialog lands with no context of its own. This gate explains *why*
/// the app wants the network first, and only starts discovery once the user
/// agrees. The acceptance is persisted, so every later tap goes straight to
/// discovery.
///
/// [startDiscovery] is the seam the widget tests fake — nothing here touches
/// the Cast plugin.
class LocalNetworkExplainerGate {
  LocalNetworkExplainerGate({
    required this.prefs,
    required this.startDiscovery,
    bool? promptsForLocalNetwork,
    Future<bool?> Function(BuildContext context)? present,
  })  : promptsForLocalNetwork = promptsForLocalNetwork ?? Platform.isIOS,
        _present = present ?? showLocalNetworkExplainerDialog;

  /// `null` when preferences are unavailable — the explainer is then skipped
  /// rather than shown on every tap with nowhere to record the answer.
  final SharedPreferences? prefs;

  /// Starts (or re-arms) Cast device discovery.
  final VoidCallback startDiscovery;

  /// Only iOS shows a system Local Network prompt; elsewhere the explainer
  /// would ask for something the platform never asks about.
  final bool promptsForLocalNetwork;

  final Future<bool?> Function(BuildContext context) _present;

  /// Whether the next tap still owes the user an explanation.
  bool get needsExplainer {
    final prefs = this.prefs;
    return promptsForLocalNetwork &&
        prefs != null &&
        !localNetworkExplainerAcknowledged(prefs);
  }

  /// Explains the upcoming system prompt when needed, then starts discovery.
  ///
  /// Returns `true` when discovery was started — `false` means the user chose
  /// "Nu acum" and nothing was touched. Declining is NOT persisted: a user who
  /// backs out deserves the same explanation the next time they try to cast.
  Future<bool> requestDiscovery(BuildContext context) async {
    if (!needsExplainer) {
      startDiscovery();
      return true;
    }
    final accepted = await _present(context) ?? false;
    if (!accepted) return false;
    await acknowledgeLocalNetworkExplainer(prefs!);
    startDiscovery();
    return true;
  }
}

/// Shows the blur-backdrop explainer. Resolves to `true` when the user taps
/// "Continuă", `false` (or `null` when dismissed) otherwise.
Future<bool?> showLocalNetworkExplainerDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.65),
    builder: (context) => BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
      child: const _LocalNetworkExplainerDialog(),
    ),
  );
}

/// Theme-aware Material 3 dialog. Private — callers use
/// [showLocalNetworkExplainerDialog].
class _LocalNetworkExplainerDialog extends StatelessWidget {
  const _LocalNetworkExplainerDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.cast_rounded, color: AppColors.primary, size: 30),
      title: const Text('Redare pe alte dispozitive'),
      content: const Text(
        'Ca să găsim televizoarele, boxele și dispozitivele Chromecast din '
        'apropiere, aplicația are nevoie de acces la rețeaua locală. Îl '
        'folosim doar pentru a reda pe alte dispozitive din casa ta. Imediat '
        'îți va apărea și cererea de permisiune a sistemului.',
        style: TextStyle(height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Nu acum'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Continuă'),
        ),
      ],
    );
  }
}
