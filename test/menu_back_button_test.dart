import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/song_actions_button.dart';
import 'package:radio_crestin/widgets/station_actions_menu.dart';

/// A long-press menu under test: what builds it, where it opens from, and
/// one of its items, which shows while it is open.
class _Menu {
  const _Menu({
    required this.name,
    required this.build,
    required this.anchor,
    required this.item,
  });

  final String name;
  final Widget Function() build;
  final Finder anchor;
  final Finder item;
}

/// BACK (Android's back button or gesture) with a long-press menu open
/// closes the menu, rather than leaving the page, or the app, with it open.
void main() {
  /// Every action the menus can run; BACK must run none of them.
  late int actions;

  /// How many times the app asked the system to leave it.
  late int appExits;

  /// What the app told Android, in order, about handling BACK itself.
  late List<bool> backHandling;

  setUp(() {
    actions = 0;
    appExits = 0;
    backHandling = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') appExits++;
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
        backHandling.add(call.arguments as bool);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  const bothPlatforms = TargetPlatformVariant(
    {TargetPlatform.iOS, TargetPlatform.android},
  );

  final home = find.text('Home');

  Widget stationRow(String name) => SizedBox(
        width: 360,
        height: 100,
        child: StationActionsMenu(
          isFavorite: false,
          onToggleFavorite: () => actions++,
          onShare: () => actions++,
          confirmHide: () async {
            actions++;
            return false;
          },
          onHide: () => actions++,
          child: ColoredBox(
            color: Colors.white,
            child: Center(child: Text(name)),
          ),
        ),
      );

  final menus = [
    _Menu(
      name: 'song menu',
      build: () => Center(
        child: SizedBox(
          width: 300,
          child: SongActionsButton(
            onSearch: () => actions++,
            onCopy: () => actions++,
            child: const Text('Artist - Song'),
          ),
        ),
      ),
      anchor: find.text('Artist - Song'),
      item: find.text(SongActionsButton.copyLabel),
    ),
    _Menu(
      name: 'station menu',
      build: () => Center(child: stationRow('Radio Test')),
      anchor: find.text('Radio Test'),
      item: find.text(StationActionsMenu.hideLabel),
    ),
  ];

  /// Pumps [content] as the app's only page, as Home is.
  Future<void> pumpFirstPage(WidgetTester tester, Widget content) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: content)));

  /// Pumps [content] on a page opened over Home.
  Future<void> pumpPageOverHome(WidgetTester tester, Widget content) =>
      tester.pumpWidget(MaterialApp(
        initialRoute: '/page',
        routes: {
          '/': (_) => const Scaffold(body: Text('Home')),
          '/page': (_) => Scaffold(body: content),
        },
      ));

  RoutePopDisposition popDisposition(WidgetTester tester, Finder anchor) =>
      ModalRoute.of(tester.element(anchor))!.popDisposition;

  for (final menu in menus) {
    group(menu.name, () {
      testWidgets('BACK closes the open menu and keeps the page',
          (tester) async {
        await pumpPageOverHome(tester, menu.build());
        await tester.longPress(menu.anchor);
        await tester.pumpAndSettle();
        expect(menu.item, findsOneWidget);

        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();

        expect(menu.item, findsNothing);
        expect(menu.anchor, findsOneWidget, reason: 'the page stays');
        expect(home, findsNothing);
        expect(actions, 0);

        // The menu opens again as before.
        await tester.longPress(menu.anchor);
        await tester.pumpAndSettle();
        expect(menu.item, findsOneWidget);
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();
        expect(menu.item, findsNothing);

        // With the menu closed, BACK leaves the page as before.
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();

        expect(menu.anchor, findsNothing);
        expect(home, findsOneWidget);
        expect(appExits, 0);
        expect(actions, 0);
      }, variant: bothPlatforms);

      testWidgets(
          'on the first page, BACK closes the open menu rather than '
          'leaving the app', (tester) async {
        await pumpFirstPage(tester, menu.build());
        await tester.longPress(menu.anchor);
        await tester.pumpAndSettle();

        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();

        expect(menu.item, findsNothing);
        expect(appExits, 0);

        // With the menu closed, BACK leaves the app as before.
        expect(await tester.binding.handlePopRoute(), isFalse);
        expect(appExits, 1);
        expect(actions, 0);
      }, variant: bothPlatforms);

      testWidgets(
          'the page holds BACK back from the moment the menu opens '
          'until it closes', (tester) async {
        // Android's predictive back needs to know before BACK starts.
        await pumpFirstPage(tester, menu.build());
        expect(popDisposition(tester, menu.anchor), RoutePopDisposition.bubble);

        await tester.longPress(menu.anchor);
        await tester.pump();
        expect(
          popDisposition(tester, menu.anchor),
          RoutePopDisposition.doNotPop,
        );
        await tester.pumpAndSettle();
        expect(
          popDisposition(tester, menu.anchor),
          RoutePopDisposition.doNotPop,
        );

        // Closed some other way, by a touch outside it.
        await tester.tapAt(const Offset(5, 5));
        await tester.pump();
        expect(popDisposition(tester, menu.anchor), RoutePopDisposition.bubble);
        await tester.pumpAndSettle();
        expect(menu.item, findsNothing);
        expect(popDisposition(tester, menu.anchor), RoutePopDisposition.bubble);
      }, variant: bothPlatforms);
    });
  }

  testWidgets('among many rows, BACK closes only the open menu',
      (tester) async {
    // Home's list: every row's menu hears of the BACK held back.
    await pumpFirstPage(
      tester,
      Column(children: [
        for (final name in ['Radio A', 'Radio B', 'Radio C']) stationRow(name),
      ]),
    );
    await tester.longPress(find.text('Radio B'));
    await tester.pumpAndSettle();
    expect(find.text(StationActionsMenu.hideLabel), findsOneWidget);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();

    expect(find.text(StationActionsMenu.hideLabel), findsNothing);
    expect(find.text('Radio A'), findsOneWidget);
    expect(find.text('Radio C'), findsOneWidget);
    expect(appExits, 0);
    expect(actions, 0);

    expect(await tester.binding.handlePopRoute(), isFalse);
    expect(appExits, 1);
  }, variant: bothPlatforms);

  testWidgets(
      'rows scrolling in and out tell Android nothing; only an opening '
      'and a closing menu do', (tester) async {
    // The app tells Android only once it runs.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpFirstPage(
      tester,
      ListView.builder(
        itemCount: 60,
        itemExtent: 100,
        itemBuilder: (_, i) => stationRow('Radio $i'),
      ),
    );
    await tester.pumpAndSettle();
    backHandling.clear();

    await tester.fling(find.byType(ListView), const Offset(0, -3000), 3000);
    await tester.pumpAndSettle();
    expect(find.text('Radio 0'), findsNothing, reason: 'rows were dropped');
    expect(backHandling, isEmpty);

    final row = find.textContaining('Radio ').first;
    await tester.longPress(row);
    await tester.pumpAndSettle();
    expect(backHandling, [true]);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text(StationActionsMenu.hideLabel), findsNothing);
    expect(backHandling, [true, false]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
