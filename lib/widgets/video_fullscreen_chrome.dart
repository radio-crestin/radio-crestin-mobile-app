import 'package:flutter/services.dart';

/// The system chrome around a YouTube player going fullscreen: landscape
/// and immersive on enter; portrait and the normal (edge-to-edge) bars on
/// exit. The player lays itself out fullscreen; this owns only the chrome.
void applyVideoFullscreenChrome(bool fullscreen) {
  if (fullscreen) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    return;
  }
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
    overlays: SystemUiOverlay.values,
  );
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
}
