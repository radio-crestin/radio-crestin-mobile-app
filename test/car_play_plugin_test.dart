import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_carplay/controllers/carplay_controller.dart';
import 'package:flutter_carplay/flutter_carplay.dart';
import 'package:flutter_carplay/helpers/carplay_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// The CarPlay plugin pieces behind the Home pinned row (iOS 26+) and the
/// Categories grid tab.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.oguzhnatly.flutter_carplay');
  late List<MethodCall> calls;
  late Object? Function(MethodCall call) answer;

  setUp(() {
    calls = [];
    answer = (_) => true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer(call);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    FlutterCarPlayController.templateHistory.clear();
    debugDefaultTargetPlatformOverride = null;
  });

  CPGridButton button(String title, [void Function()? onPress]) =>
      CPGridButton(
        titleVariants: [title],
        image: 'sf:music.note',
        onPress: onPress ?? () {},
      );

  CPListTemplate list({
    List<CPGridButton> pinned = const [],
    CPImageRow? row,
  }) =>
      CPListTemplate(
        title: 'Acasă',
        sections: [CPListSection(items: [CPListItem(text: 'RVE')])],
        systemIcon: 'house.fill',
        headerGridButtons: pinned,
        headerImageRow: row,
      );

  CPImageRowElement picture(String title, [void Function()? onPress]) =>
      CPImageRowElement(
        title: title,
        image: 'https://example.com/$title.png',
        onPress: onPress ?? () {},
      );

  group('templates sent to iOS', () {
    test('a list carries its pinned buttons', () {
      final json = list(pinned: [button('Radio Gosen')]).toJson();

      final pinned = json['headerGridButtons'] as List;
      expect(pinned, hasLength(1));
      expect((pinned.single as Map)['titleVariants'], ['Radio Gosen']);
    });

    test('a list without pinned buttons sends an empty row', () {
      expect(list().toJson()['headerGridButtons'], isEmpty);
    });

    test('a list carries its titled row of pictures', () {
      final row = CPImageRow(
        title: 'Favorite',
        elements: [picture('Radio Gosen')],
        onTitlePress: () {},
      );

      final json = list(row: row).toJson()['headerImageRow'] as Map;

      expect(json['title'], 'Favorite');
      expect(json['allowsMultipleLines'], isTrue);
      expect(json['onTitlePress'], isTrue);
      final element = (json['elements'] as List).single as Map;
      expect(element['title'], 'Radio Gosen');
      expect(element['image'], 'https://example.com/Radio Gosen.png');
    });

    test('a row without a title action says so, a list without a row '
        'sends none', () {
      final row = CPImageRow(title: 'Populare acum', elements: const []);

      expect(row.toJson()['onTitlePress'], isFalse);
      expect(list().toJson()['headerImageRow'], isNull);
    });

    test('a grid carries its tab icon', () {
      final grid = CPGridTemplate(
        title: 'Categorii',
        buttons: [button('Muzica')],
        systemIcon: 'square.grid.2x2.fill',
      );

      expect(grid.toJson()['systemIcon'], 'square.grid.2x2.fill');
    });
  });

  group('finding a pressed grid button', () {
    final helper = FlutterCarplayHelper();

    test('in a grid tab and in a pinned row of a list tab', () {
      final pinned = button('Radio Gosen');
      final category = button('Muzica');
      final tabBar = CPTabBarTemplate(templates: [
        list(pinned: [pinned]),
        CPGridTemplate(title: 'Categorii', buttons: [category]),
      ]);

      expect(
        helper.findCPGridButton(
            templates: [tabBar], elementId: pinned.uniqueId),
        same(pinned),
      );
      expect(
        helper.findCPGridButton(
            templates: [tabBar], elementId: category.uniqueId),
        same(category),
      );
      expect(
        helper.findCPGridButton(templates: [tabBar], elementId: 'missing'),
        isNull,
      );
    });

    test('a press reaches the pinned button of the Home tab', () {
      var pressed = 0;
      final pinned = button('Radio Gosen', () => pressed++);
      FlutterCarPlayController.templateHistory.add(
        CPTabBarTemplate(templates: [list(pinned: [pinned])]),
      );

      FlutterCarPlayController().processFCPGridButtonPressed(pinned.uniqueId);

      expect(pressed, 1);
    });
  });

  group('pressing the titled row of pictures', () {
    final helper = FlutterCarplayHelper();

    test('a picture press reaches its station on the Home tab', () {
      var pressed = '';
      final gosen = picture('Radio Gosen', () => pressed = 'gosen');
      final rve = picture('RVE', () => pressed = 'rve');
      FlutterCarPlayController.templateHistory.add(CPTabBarTemplate(
        templates: [
          list(row: CPImageRow(title: 'Favorite', elements: [gosen, rve])),
        ],
      ));

      FlutterCarPlayController().processFCPImageRowElementPressed(rve.uniqueId);

      expect(pressed, 'rve');
    });

    test('a title press reaches the row', () {
      var opened = 0;
      final row = CPImageRow(
        title: 'Favorite',
        elements: [picture('Radio Gosen')],
        onTitlePress: () => opened++,
      );
      FlutterCarPlayController.templateHistory.add(list(row: row));

      FlutterCarPlayController().processFCPImageRowTitlePressed(row.uniqueId);

      expect(opened, 1);
    });

    test('unknown ids find nothing', () {
      final templates = [list(row: CPImageRow(title: 'F', elements: []))];

      expect(
        helper.findCPImageRowElement(templates: templates, elementId: 'x'),
        isNull,
      );
      expect(helper.findCPImageRow(templates: templates, elementId: 'x'),
          isNull);
    });
  });

  group('FlutterCarplay.getCapabilities', () {
    test('reads what iOS reports', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      answer = (_) => {
            'supportsHeaderGridButtons': true,
            'maximumHeaderGridButtonCount': 9,
            'supportsHeaderImageRow': true,
            'maximumHeaderImageRowCount': 24,
          };

      final capabilities = await FlutterCarplay.getCapabilities();

      expect(capabilities.supportsHeaderGridButtons, isTrue);
      expect(capabilities.maximumHeaderGridButtonCount, 9);
      expect(capabilities.supportsHeaderImageRow, isTrue);
      expect(capabilities.maximumHeaderImageRowCount, 24);
      expect(calls.single.method, 'getCapabilities');
    });

    test('falls back to the iOS 15 feature set when iOS fails', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      answer = (_) => throw PlatformException(code: 'ERROR');

      final capabilities = await FlutterCarplay.getCapabilities();

      expect(capabilities.supportsHeaderGridButtons, isFalse);
      expect(capabilities.supportsHeaderImageRow, isFalse);
    });

    test('does not ask off iOS', () async {
      final capabilities = await FlutterCarplay.getCapabilities();

      expect(capabilities.supportsHeaderGridButtons, isFalse);
      expect(calls, isEmpty);
    });
  });

  test('updating the pinned row reaches iOS and the kept template', () async {
    final home = list(pinned: [button('Old')]);
    FlutterCarPlayController.templateHistory.add(
      CPTabBarTemplate(templates: [home]),
    );
    final replacement = button('Radio Gosen');

    await FlutterCarplay().updateListTemplateHeaderGridButtons(
      elementId: home.uniqueId,
      buttons: [replacement],
    );

    final call = calls.single;
    expect(call.method, 'updateListTemplateHeaderGridButtons');
    expect((call.arguments as Map)['elementId'], home.uniqueId);
    expect(home.headerGridButtons, [replacement]);
  });

  test('updating the row of pictures reaches iOS and the kept template',
      () async {
    final home = list(row: CPImageRow(title: 'Favorite', elements: []));
    FlutterCarPlayController.templateHistory.add(
      CPTabBarTemplate(templates: [home]),
    );
    final replacement = CPImageRow(
      title: 'Favorite',
      elements: [picture('Radio Gosen')],
    );

    await FlutterCarplay().updateListTemplateHeaderImageRow(
      elementId: home.uniqueId,
      row: replacement,
    );

    final call = calls.single;
    expect(call.method, 'updateListTemplateHeaderImageRow');
    final args = call.arguments as Map;
    expect(args['elementId'], home.uniqueId);
    expect((args['row'] as Map)['_elementId'], replacement.uniqueId);
    expect(home.headerImageRow, same(replacement));
  });

  test('a tab bar update sent before iOS answered a list update carries '
      'the new list, so iOS keeps it', () async {
    // Hiding a station updates Home, then the Categories tab (its station
    // counts), which sends Home along with it.
    final home = list(row: CPImageRow(title: 'Favorite', elements: []));
    final tabBar = CPTabBarTemplate(templates: [home]);
    FlutterCarPlayController.templateHistory.add(tabBar);
    final carplay = FlutterCarplay();
    final row = CPImageRow(title: 'Favorite', elements: [picture('Gosen')]);
    final pinned = button('Radio Gosen');

    final updates = [
      carplay.updateListTemplateSections(
        elementId: home.uniqueId,
        sections: [CPListSection(items: [CPListItem(text: 'Gosen')])],
      ),
      carplay.updateListTemplateHeaderImageRow(
          elementId: home.uniqueId, row: row),
      carplay.updateListTemplateHeaderGridButtons(
          elementId: home.uniqueId, buttons: [pinned]),
      carplay.updateTabBarTemplates(
          elementId: tabBar.uniqueId, templates: [home]),
    ];
    await Future.wait(updates);

    final sent = calls.last;
    expect(sent.method, 'updateTabBarTemplates');
    final homeJson = ((sent.arguments as Map)['templates'] as List).single
        as Map;
    final items = ((homeJson['sections'] as List).single as Map)['items'];
    expect([for (final item in items as List) (item as Map)['text']],
        ['Gosen']);
    expect((homeJson['headerImageRow'] as Map)['_elementId'], row.uniqueId);
    expect((homeJson['headerGridButtons'] as List).single['_elementId'],
        pinned.uniqueId);
  });
}
