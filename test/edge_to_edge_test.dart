import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/widgets/edge_to_edge.dart';
import 'package:radio_crestin/widgets/pinned_title_sliver_header.dart';

void main() {
  for (final (name, theme) in [('light', lightTheme), ('dark', darkTheme)]) {
    // Each new style relays out the window on Android 10 and earlier.
    testWidgets('$name: changing pages keeps the system bars\' style',
        (tester) async {
      EdgeToEdge.enabledForTesting = true;
      addTearDown(() => EdgeToEdge.enabledForTesting = false);
      final styles = <Object?>[];
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setSystemUIOverlayStyle') {
          styles.add(call.arguments);
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        navigatorKey: navigator,
        builder: (context, child) => EdgeToEdgeNavigationBar(child: child!),
        home: const Scaffold(body: Text('Home')),
      ));
      await tester.pumpAndSettle();
      styles.clear();

      navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          body: CustomScrollView(
            slivers: [PinnedTitleSliverHeader(title: 'Setări')],
          ),
        ),
      ));
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      expect(styles, isEmpty);
    });
  }
}
