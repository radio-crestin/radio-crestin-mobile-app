import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/car_play_layout.dart';
import 'package:radio_crestin/services/car_play_service.dart';

void main() {
  group('CarHomeLayout with the pinned row (iOS 26+)', () {
    const sorted = ['a', 'b', 'c', 'd', 'e', 'f', 'g'];

    CarHomeLayout layout({
      List<String> slugs = sorted,
      List<String> favorites = const [],
      Map<String, int> plays = const {},
      int maxPinned = 24,
    }) =>
        CarHomeLayout.compute(
          sortedSlugs: slugs,
          favoriteSlugs: favorites,
          playCounts: plays,
          usePinnedRow: true,
          maxPinned: maxPinned,
        );

    test('pins favorites, most played first, ties in the listener\'s order',
        () {
      final result = layout(
        favorites: ['d', 'b', 'f'],
        plays: {'f': 4, 'b': 1, 'd': 1},
      );

      expect(result.pinned, ['f', 'd', 'b']);
      expect(result.hiddenFavoriteCount, 0);
      expect(result.favorites, isEmpty);
      expect(result.hasFavorites, isTrue);
    });

    test('keeps the last slot for "all favorites" when they overflow', () {
      final many = [for (var i = 0; i < 10; i++) 's$i'];
      final result = layout(
        slugs: many,
        favorites: many,
        plays: {'s9': 9, 's8': 5},
      );

      expect(result.pinned, ['s9', 's8', 's0', 's1', 's2', 's3', 's4']);
      expect(result.hiddenFavoriteCount, 3);
    });

    test('pins eight favorites, about two lines, though CarPlay takes 24',
        () {
      final eight = [for (var i = 0; i < 8; i++) 's$i'];
      final result = layout(slugs: eight, favorites: eight);

      expect(result.pinned, eight);
      expect(result.hiddenFavoriteCount, 0);
    });

    test('a smaller CarPlay limit wins over the row size', () {
      final result = layout(favorites: ['a', 'b', 'c'], maxPinned: 2);

      expect(result.pinned, ['a']);
      expect(result.hiddenFavoriteCount, 2);
    });

    test('fills the row exactly when favorites match the limit', () {
      final result = layout(favorites: ['a', 'b', 'c'], maxPinned: 3);

      expect(result.pinned, ['a', 'b', 'c']);
      expect(result.hiddenFavoriteCount, 0);
    });

    test('without favorites pins nothing, so Home shows the hint', () {
      final result = layout(plays: {'g': 9, 'c': 4});

      expect(result.pinned, isEmpty);
      expect(result.hiddenFavoriteCount, 0);
      expect(result.favorites, isEmpty);
      expect(result.hasFavorites, isFalse);
    });

    test('lists every station in app order', () {
      expect(layout().all, sorted);
    });

    test('falls back to sections when fewer than two buttons fit', () {
      final result = layout(favorites: ['a', 'b'], maxPinned: 1);

      expect(result.pinned, isEmpty);
      expect(result.favorites, ['a', 'b']);
      expect(result.hasFavorites, isTrue);
    });
  });

  group('CarHomeLayout without the pinned row (iOS 15–25)', () {
    CarHomeLayout layout({
      List<String> favorites = const [],
      Map<String, int> plays = const {},
    }) =>
        CarHomeLayout.compute(
          sortedSlugs: const ['a', 'b', 'c', 'd'],
          favoriteSlugs: favorites,
          playCounts: plays,
          usePinnedRow: false,
          maxPinned: 9,
        );

    test('lists favorites in the listener\'s order in their own section',
        () {
      final result = layout(favorites: ['c', 'a'], plays: {'a': 9});

      expect(result.pinned, isEmpty);
      expect(result.favorites, ['c', 'a']);
      expect(result.hasFavorites, isTrue);
    });

    test('leaves out favorites the app no longer lists', () {
      final result = layout(favorites: ['gone', 'b']);

      expect(result.favorites, ['b']);
    });

    test('a new listener gets the hint and the full list', () {
      final result = layout();

      expect(result.favorites, isEmpty);
      expect(result.hasFavorites, isFalse);
      expect(result.all, ['a', 'b', 'c', 'd']);
    });
  });

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
          ['G0', 'G1', 'G2', 'G3', 'G4', 'G5', 'G6']);
      expect(result.more.map((c) => c.name), ['G7', 'G8', 'G9', 'G10', 'G11']);
    });

    test('Copii and Biblia keep a button when not all fit', () {
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
        'General', 'Muzica', 'Emisiuni', 'Popular', 'Predici', 'Copii',
        'Biblia',
      ]);
      expect(result.more.map((c) => c.name),
          ['Worship', 'International', 'Gospel', 'Instrumental', 'Colinde']);
    });

    test('shows all eight when exactly eight fit', () {
      final groups = [for (var i = 0; i < 8; i++) group(i, 'G$i', {i})];

      final result = CarCategoryLayout.compute(
        groups: groups,
        knownStationIds: {for (var i = 0; i < 20; i++) i},
      );

      expect(result.onGrid, hasLength(8));
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
