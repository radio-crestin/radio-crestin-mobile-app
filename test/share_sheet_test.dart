import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/widgets/share_sheet.dart';

const _stationUrl = 'https://www.radiocrestin.ro/aripi-spre-cer';

ShareLinkData _linkData({int visitCount = 0}) => ShareLinkData(
      shareId: 'abc',
      url: 'https://asculta.radiocrestin.ro',
      shareMessage: '',
      shareStationMessage: '',
      visitCount: visitCount,
      createdAt: '',
      isActive: true,
      shareSectionMessage: '',
      shareSectionTitle: '',
    );

void main() {
  late List<String> clipboard;

  setUp(() {
    clipboard = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await GetIt.instance.reset();
  });

  /// Pumps an app whose only button opens the sheet, on [platform].
  Future<void> pumpHost(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
    Brightness brightness = Brightness.light,
    String? stationName = 'Aripi Spre Cer',
    ShareLinkData? initialData,
    Future<ShareLinkData?> Function()? loader,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform, brightness: brightness),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => ShareSheet.show(
                  context,
                  shareUrl: _stationUrl,
                  shareMessage: 'Instalează aplicația:\n$_stationUrl',
                  stationName: stationName,
                  songId: 5,
                  initialData: initialData,
                  loader: loader,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The action a screen reader announces as [label]; tapping its center
  /// hits the ripple layer over the circle and the label.
  Finder action(String label) => find.bySemanticsLabel(label);

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    group('on ${platform.name}', () {
      testWidgets('invites to the station with four actions', (tester) async {
        await pumpHost(tester, platform: platform);
        await openSheet(tester);

        expect(find.text('Invită un prieten să asculte'), findsOneWidget);
        expect(
          find.text('Aripi Spre Cer · radio creștin, gratuit'),
          findsOneWidget,
        );
        for (final label in ['WhatsApp', 'Facebook', 'Copiază', 'Mai multe']) {
          expect(find.text(label), findsOneWidget);
        }
        expect(
          find.byIcon(
            platform == TargetPlatform.iOS
                ? Icons.ios_share_rounded
                : Icons.share_rounded,
          ),
          findsOneWidget,
        );
      });

      testWidgets('copying confirms in place and turns back', (tester) async {
        await pumpHost(tester, platform: platform);
        await openSheet(tester);

        await tester.tap(action('Copiază linkul'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(clipboard, [_stationUrl]);
        expect(find.text('Copiat'), findsOneWidget);
        expect(find.text('Invită un prieten să asculte'), findsOneWidget);

        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text('Copiază'), findsOneWidget);
      });
    });
  }

  testWidgets('shares the app when there is no station', (tester) async {
    await pumpHost(tester, stationName: null);
    await openSheet(tester);

    expect(
      find.text('Radio Creștin · peste 60 de stații, gratuit'),
      findsOneWidget,
    );
  });

  testWidgets('copies the personal link once it has loaded', (tester) async {
    await pumpHost(tester, initialData: _linkData());
    await openSheet(tester);

    await tester.tap(action('Copiază linkul'));
    await tester.pump();
    expect(clipboard, [
      'https://asculta.radiocrestin.ro/aripi-spre-cer?s=abc&song=5',
    ]);
    await tester.pumpAndSettle(const Duration(seconds: 2));
  });

  testWidgets('shows the visit count once the loader answers',
      (tester) async {
    final link = Completer<ShareLinkData?>();
    await pumpHost(tester, loader: () => link.future);
    await openSheet(tester);
    expect(find.byIcon(Icons.people_outline_rounded), findsNothing);

    link.complete(_linkData(visitCount: 24));
    await tester.pumpAndSettle();
    expect(
      find.text('24 de prieteni au deschis invitația ta'),
      findsOneWidget,
    );
  });

  testWidgets('opens with the cached count while it refreshes',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
    await ShareLinkCache.save(_linkData(visitCount: 24));

    final link = Completer<ShareLinkData?>();
    await pumpHost(tester, loader: () => link.future);
    await openSheet(tester);
    expect(
      find.text('24 de prieteni au deschis invitația ta'),
      findsOneWidget,
    );

    link.complete(_linkData(visitCount: 25));
    await tester.pumpAndSettle();
    expect(
      find.text('25 de prieteni au deschis invitația ta'),
      findsOneWidget,
    );
  });

  testWidgets('hides the footer when the link cannot be loaded',
      (tester) async {
    await pumpHost(tester, loader: () async => null);
    await openSheet(tester);

    expect(find.byIcon(Icons.people_outline_rounded), findsNothing);
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('shows a known visit count right away', (tester) async {
    await pumpHost(tester, initialData: _linkData());
    await openSheet(tester);

    expect(
      find.text('Niciun prieten n-a deschis încă invitația ta'),
      findsOneWidget,
    );
  });

  testWidgets('highlights the friends who came in', (tester) async {
    await pumpHost(tester, initialData: _linkData(visitCount: 24));
    await openSheet(tester);

    final text = tester.widget<Text>(
      find.text('24 de prieteni au deschis invitația ta'),
    );
    final span = text.textSpan! as TextSpan;
    final friends = span.children!.first as TextSpan;
    expect(friends.text, '24 de prieteni');
    expect(friends.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('"Mai multe" closes the sheet too', (tester) async {
    await pumpHost(tester, platform: TargetPlatform.iOS);
    await openSheet(tester);

    await tester.tap(action('Mai multe'));
    await tester.pumpAndSettle();
    expect(find.text('Invită un prieten să asculte'), findsNothing);
  });

  testWidgets('a share target closes the sheet', (tester) async {
    await pumpHost(tester, brightness: Brightness.dark);
    await openSheet(tester);

    await tester.tap(action('Facebook'));
    await tester.pumpAndSettle();
    expect(find.text('Invită un prieten să asculte'), findsNothing);
  });
}
