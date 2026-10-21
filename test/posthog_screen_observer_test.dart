import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_flutter/src/posthog_flutter_platform_interface.dart';

import 'package:radio_crestin/services/posthog_screen_observer.dart';
import 'package:radio_crestin/theme.dart';

class _ScreenRecorder extends PosthogFlutterPlatformInterface {
  final screens = <String>[];

  @override
  Future<void> screen({
    required String screenName,
    Map<String, Object>? properties,
  }) async =>
      screens.add(screenName);
}

void main() {
  testWidgets('records a screen once its page has finished changing',
      (tester) async {
    final recorder = _ScreenRecorder();
    PosthogFlutterPlatformInterface.instance = recorder;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      theme: darkTheme,
      navigatorKey: navigator,
      navigatorObservers: [PosthogScreenObserver()],
      home: const Text('Home'),
    ));
    expect(recorder.screens, ["root ('/')"]);

    navigator.currentState!.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/settings'),
      builder: (_) => const Text('Setări'),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(recorder.screens, ["root ('/')"]);
    await tester.pumpAndSettle();
    expect(recorder.screens, ["root ('/')", '/settings']);

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(recorder.screens, hasLength(2));
    await tester.pumpAndSettle();
    expect(recorder.screens, ["root ('/')", '/settings', "root ('/')"]);
  });
}
