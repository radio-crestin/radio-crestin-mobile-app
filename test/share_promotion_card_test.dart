import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/widgets/share_promotion_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _title = 'Ajută la răspândirea Evangheliei';

/// The API's `share_link` object, as `ShareLinkCache` saves it too.
Map<String, dynamic> _shareLink({int visitCount = 0}) => {
      'share_id': 'abc',
      'url': 'https://asculta.radiocrestin.ro',
      'share_message': '',
      'share_station_message': '',
      'visit_count': visitCount,
      'created_at': '2026-10-14T00:00:00Z',
      'is_active': true,
      'share_section_message': 'Trimite această aplicație prietenilor tăi '
          'pentru a-L cunoaște pe Mântuitorul și Salvatorul lumii.',
      'share_section_title': _title,
    };

void main() {
  /// One pending answer per share link request, completed by the test.
  late List<Completer<Map<String, dynamic>>> requests;
  final cardKey = GlobalKey<SharePromotionCardState>();

  tearDown(() => GetIt.instance.reset());

  Future<void> pumpCard(
    WidgetTester tester, {
    Map<String, dynamic>? cached,
  }) async {
    SharedPreferences.setMockInitialValues({
      'device_id': 'device',
      if (cached != null) 'share_link_cache': jsonEncode(cached),
    });
    GetIt.instance.registerSingleton<SharedPreferences>(
      await SharedPreferences.getInstance(),
    );
    requests = [];
    final client = GraphQLClient(
      cache: GraphQLCache(),
      link: Link.function((request, [forward]) async* {
        final answer = Completer<Map<String, dynamic>>();
        requests.add(answer);
        yield Response(
          data: {
            'get_share_link': {'share_link': await answer.future},
          },
          response: const {},
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [SharePromotionCard(key: cardKey, client: client)],
          ),
        ),
      ),
    );
  }

  /// Answers the share link request in flight with [link].
  Future<void> answer(WidgetTester tester, Map<String, dynamic> link) async {
    await tester.pump();
    requests.last.complete(link);
    // The client hands the result over a frame after the link answers.
    await tester.pump();
    await tester.pump();
  }

  Size cardSize(WidgetTester tester) =>
      tester.getSize(find.byType(SharePromotionCard));

  testWidgets('draws the cached link on its first frame', (tester) async {
    await pumpCard(tester, cached: _shareLink());

    expect(find.text(_title), findsOneWidget);
    expect(
      find.text('Niciun prieten nu a accesat link-ul tău'),
      findsOneWidget,
    );
    await answer(tester, _shareLink());
  });

  testWidgets('keeps its size when the fresh link arrives', (tester) async {
    await pumpCard(tester, cached: _shareLink());
    final before = cardSize(tester);

    await answer(tester, _shareLink(visitCount: 2));

    expect(find.text('2 prieteni au accesat invitația ta'), findsOneWidget);
    expect(cardSize(tester), before);
  });

  testWidgets('stays on screen while a refresh loads', (tester) async {
    await pumpCard(tester, cached: _shareLink());
    await answer(tester, _shareLink(visitCount: 2));
    final before = cardSize(tester);

    unawaited(cardKey.currentState!.refreshShareLink());
    await tester.pump();

    expect(find.text('2 prieteni au accesat invitația ta'), findsOneWidget);
    expect(cardSize(tester), before);

    await answer(tester, _shareLink(visitCount: 3));
    expect(find.text('3 prieteni au accesat invitația ta'), findsOneWidget);
  });

  testWidgets('shows once the first link arrives when none is cached',
      (tester) async {
    await pumpCard(tester);
    expect(find.text(_title), findsNothing);

    await answer(tester, _shareLink());

    expect(find.text(_title), findsOneWidget);
  });
}
