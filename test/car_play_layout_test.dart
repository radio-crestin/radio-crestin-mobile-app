import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/car_play_layout.dart';
import 'package:radio_crestin/services/car_play_service.dart';

void main() {
  group('CarCategoryLayout', () {
    CarCategory group(int id, String name, Set<int> stations) => CarCategory(
          id: id,
          slug: name.toLowerCase(),
          name: name,
          stationIds: stations,
        );

    test('drops empty groups and the group holding every station', () {
      final result = CarCategoryLayout.compute(
        groups: [
          group(12, 'Toate', {1, 2, 3, 4}),
          group(1, 'Muzica', {1, 2}),
          group(2, 'Copii', {99}),
          group(3, 'Predici', {3}),
        ],
        knownStationIds: {1, 2, 3, 4, 5},
      );

      expect(result.onGrid.map((c) => c.name), ['Muzica', 'Predici']);
      expect(result.more, isEmpty);
    });

    test('keeps only stations the app knows about', () {
      final result = CarCategoryLayout.compute(
        groups: [
          group(1, 'Muzica', {1, 2, 99}),
          group(2, 'Predici', {3}),
        ],
        knownStationIds: {1, 2, 3},
      );

      expect(result.onGrid.first.stationIds, {1, 2});
    });

    test('puts the rest behind "More" when they do not fit', () {
      final groups = [
        for (var i = 0; i < 12; i++) group(i, 'G$i', {i, 100}),
      ];

      final result = CarCategoryLayout.compute(
        groups: groups,
        knownStationIds: {for (var i = 0; i <= 100; i++) i},
      );

      expect(result.onGrid.map((c) => c.name),
          ['G0', 'G1', 'G2', 'G3', 'G4', 'G5'],
          reason: 'beside "Toate radiourile" and "More"');
      expect(result.more.map((c) => c.name),
          ['G6', 'G7', 'G8', 'G9', 'G10', 'G11']);
    });

    test('General, Copii and Popular come first, then the API order', () {
      // The API's order on 2026-10-14.
      const names = [
        'General', 'Muzica', 'Emisiuni', 'Popular', 'Predici', 'Worship',
        'International', 'Gospel', 'Instrumental', 'Copii', 'Biblia',
        'Colinde',
      ];
      final groups = [
        for (var i = 0; i < names.length; i++) group(i, names[i], {i}),
      ];

      final result = CarCategoryLayout.compute(
        groups: groups,
        knownStationIds: {for (var i = 0; i < 20; i++) i},
      );

      expect(result.onGrid.map((c) => c.name), [
        'General', 'Copii', 'Popular', 'Muzica', 'Emisiuni', 'Predici',
      ]);
      expect(result.more.map((c) => c.name), [
        'Worship', 'International', 'Gospel', 'Instrumental', 'Biblia',
        'Colinde',
      ]);
    });

    test('the first ones lead even when every category fits', () {
      final groups = [
        group(1, 'Muzica', {1}),
        group(2, 'Popular', {2}),
        group(3, 'Copii', {3}),
      ];

      final result = CarCategoryLayout.compute(
        groups: groups,
        knownStationIds: {1, 2, 3, 4},
      );

      expect(result.onGrid.map((c) => c.name), ['Copii', 'Popular', 'Muzica']);
      expect(result.more, isEmpty);
    });

    test('shows all seven beside "Toate radiourile" when exactly seven fit',
        () {
      final groups = [for (var i = 0; i < 7; i++) group(i, 'G$i', {i})];

      final result = CarCategoryLayout.compute(
        groups: groups,
        knownStationIds: {for (var i = 0; i < 20; i++) i},
      );

      expect(result.onGrid, hasLength(7));
      expect(result.more, isEmpty);
    });

    test('the signature changes only with what the grid shows', () {
      CarCategoryLayout build(Set<int> muzica) => CarCategoryLayout.compute(
            groups: [group(1, 'Muzica', muzica), group(2, 'Predici', {3})],
            knownStationIds: {1, 2, 3, 4},
          );

      expect(build({1, 2}).signature, build({2, 1}).signature);
      expect(build({1, 2}).signature, isNot(build({1}).signature));
    });

    test('known group slugs get their own symbol', () {
      expect(group(1, 'Muzica', {1}).symbol, 'music.note');
      expect(group(2, 'Necunoscut', {1}).symbol, 'square.grid.2x2');
    });

    test('every category has an Android Auto icon in the app', () {
      const slugs = [
        'general', 'muzica', 'emisiuni', 'popular', 'predici', 'worship',
        'international', 'gospel', 'instrumental', 'copii', 'biblia',
        'colinde', 'necunoscut',
      ];
      final icons = {for (final s in slugs) s: group(1, s, {1}).androidIcon};

      expect(icons['muzica'], 'ic_category_muzica');
      expect(icons['necunoscut'], 'ic_category_other');
      for (final icon in [...icons.values, 'ic_category_all']) {
        expect(
          File('android/app/src/main/res/drawable/$icon.xml').existsSync(),
          isTrue,
          reason: '$icon is drawn by Android Auto from res/drawable',
        );
      }
    });
  });

  group('CarPlayService.stationCountText', () {
    String ro(int n) => CarPlayService.stationCountText(n, isRomanian: true);
    String en(int n) => CarPlayService.stationCountText(n, isRomanian: false);

    test('Romanian adds "de" from 20 up, except 101-119 and similar', () {
      expect(ro(1), '1 stație');
      expect(ro(5), '5 stații');
      expect(ro(19), '19 stații');
      expect(ro(20), '20 de stații');
      expect(ro(38), '38 de stații');
      expect(ro(100), '100 de stații');
      expect(ro(105), '105 stații');
    });

    test('English', () {
      expect(en(1), '1 station');
      expect(en(23), '23 stations');
    });
  });
}
