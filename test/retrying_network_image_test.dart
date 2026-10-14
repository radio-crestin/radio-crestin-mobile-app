import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/widgets/retrying_network_image.dart';

import 'helpers/fake_image_http.dart';

Widget _app() => const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 60,
          height: 60,
          child: RetryingNetworkImage(
            url: 'https://cdn.example.com/logo.png',
            loading: _loading,
            failed: _failed,
          ),
        ),
      ),
    );

Widget _loading(BuildContext context) => const Text('loading');
Widget _failed(BuildContext context) => const Text('failed');

void main() {
  late FakeImageHttpClient http;
  late NetworkService network;

  setUp(() {
    http = FakeImageHttpClient();
    network = NetworkService();
  });

  tearDown(() => network.dispose());

  testImageWidgets(
      'an image that failed offline loads once the internet is back',
      () => http, (tester) async {
    network.isOffline.add(true);
    await tester.pumpWidget(_app());
    await waitFor(tester, find.text('failed'));

    http.fallback = FakeImageAnswer.image;
    network.isOffline.add(false);
    await tester.pump();

    // The placeholder stays while the image loads again, never the
    // loading look.
    expect(find.text('failed'), findsOneWidget);
    expect(find.text('loading'), findsNothing);

    await waitFor(tester, loadedImage);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('failed'), findsNothing);
    expect(loadedImage, findsOneWidget);
  });

  testImageWidgets('a failed image loads again when the app comes back',
      () => http, (tester) async {
    await tester.pumpWidget(_app());
    await waitFor(tester, find.text('failed'));

    http.fallback = FakeImageAnswer.image;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }

    await waitFor(tester, loadedImage);
  });

  testImageWidgets('nothing is requested again while still offline',
      () => http, (tester) async {
    network.isOffline.add(true);
    await tester.pumpWidget(_app());
    await waitFor(tester, find.text('failed'));
    final requests = http.requests;

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(http.requests, requests);
    expect(find.text('failed'), findsOneWidget);
  });
}
