import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/station_group_categories.dart';
import 'package:radio_crestin/tv/desktop/desktop_browse_model.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

Station _station(
  int id,
  String slug,
  String title, {
  String? song,
  String? artist,
}) =>
    StationFactory.createStation(
      id: id,
      slug: slug,
      title: title,
      nowPlaying: song == null
          ? null
          : StationFactory.createNowPlaying(
              id: id * 10,
              songName: song,
              artistName: artist,
            ),
    );

List<String> _slugs(List<Station> stations) =>
    [for (final station in stations) station.slug as String];

void main() {
  final alpha = _station(1, 'alpha', 'Radio Alpha');
  final bravo = _station(2, 'bravo', 'Radio Bravo');
  final cluj = _station(3, 'cluj', 'RVE Cluj', song: 'Lauda', artist: 'Bravo');
  final delta = _station(4, 'delta', 'Delta Worship');
  final listed = [alpha, bravo, cluj, delta];

  group('DesktopBrowseContent.compute', () {
    test('lists the favorites in the listener\'s order, and keeps them in '
        'the main section too', () {
      final content = DesktopBrowseContent.compute(
        listed: listed,
        favoriteSlugs: ['delta', 'alpha'],
        categoryChosen: false,
      );

      expect(_slugs(content.favorites), ['delta', 'alpha']);
      expect(_slugs(content.stations), ['alpha', 'bravo', 'cluj', 'delta']);
      expect(content.showsHidden, isFalse);
    });

    test('leaves out favorites the list does not show (hidden, gone)', () {
      final content = DesktopBrowseContent.compute(
        listed: [alpha, bravo],
        favoriteSlugs: ['gone', 'bravo', 'delta'],
        categoryChosen: false,
      );

      expect(_slugs(content.favorites), ['bravo']);
    });

    test('hides the Favorite section while a category is chosen', () {
      final content = DesktopBrowseContent.compute(
        listed: [alpha, delta],
        favoriteSlugs: ['alpha'],
        categoryChosen: true,
      );

      expect(content.favorites, isEmpty);
      expect(_slugs(content.stations), ['alpha', 'delta']);
    });

    test('a category shown with its hidden stations keeps them out of the '
        'favorites', () {
      final content = DesktopBrowseContent.compute(
        listed: [alpha, bravo],
        favoriteSlugs: ['alpha'],
        categoryChosen: false,
        shownHidden: {'alpha'},
      );

      expect(content.favorites, isEmpty);
      expect(content.showsHidden, isTrue);
    });
  });

  group('desktopSearchResults', () {
    test('lists the stations found by name first, then by song', () {
      // "bravo" names Radio Bravo and is the singer on RVE Cluj.
      final results = desktopSearchResults(listed, 'bravo');

      expect(_slugs(results), ['bravo', 'cluj']);
    });

    test('ignores case and diacritics', () {
      final results = desktopSearchResults(
        [_station(9, 'ss', 'Speranța', song: 'Țara mea')],
        'SPERANTA',
      );

      expect(_slugs(results), ['ss']);
      expect(
        _slugs(desktopSearchResults(
          [_station(9, 'ss', 'Speranța', song: 'Țara mea')],
          'tara',
        )),
        ['ss'],
      );
    });

    test('finds nothing for a query that matches nothing', () {
      expect(desktopSearchResults(listed, 'xyz'), isEmpty);
    });
  });

  group('movedHighlight', () {
    test('moves down and up, wrapping around at the ends', () {
      expect(movedHighlight(listed, 'alpha', down: true), 'bravo');
      expect(movedHighlight(listed, 'delta', down: true), 'alpha');
      expect(movedHighlight(listed, 'alpha', down: false), 'delta');
    });

    test('starts at the first going down and the last going up', () {
      expect(movedHighlight(listed, null, down: true), 'alpha');
      expect(movedHighlight(listed, null, down: false), 'delta');
      expect(movedHighlight(listed, 'gone', down: true), 'alpha');
    });

    test('passes over the stations on their way out', () {
      expect(
        movedHighlight(listed, 'alpha', down: true, skipped: {'bravo'}),
        'cluj',
      );
    });

    test('is null without results', () {
      expect(movedHighlight(const [], null, down: true), isNull);
    });
  });

  group('DesktopGridMetrics.forWidth', () {
    DesktopGridMetrics metrics(double width) => DesktopGridMetrics.forWidth(
          width,
          maxTileWidth: 220,
          spacing: 16,
          extraHeight: 70,
        );

    test('fills the row edge to edge, cards at most the widest', () {
      for (final width in [712.0, 1000.0, 1232.0, 1872.0, 2512.0]) {
        final m = metrics(width);
        expect(m.tileWidth, lessThanOrEqualTo(220), reason: '$width');
        expect(
          m.columns * m.tileWidth + (m.columns - 1) * 16,
          closeTo(width, 0.001),
          reason: '$width',
        );
        expect(m.tileHeight, m.tileWidth + 70);
      }
    });

    test('takes more columns as the window widens', () {
      expect(metrics(712).columns, 4); // A 760 px window.
      expect(metrics(1232).columns, 6); // 1280 px.
      expect(metrics(2512).columns, 11); // 2560 px.
    });

    test('keeps at least two columns in a very narrow space', () {
      final m = metrics(200);
      expect(m.columns, 2);
      expect(m.tileWidth, 92);
      expect(metrics(-10).tileWidth, 0);
    });
  });

  group('hiddenInCategoryNote', () {
    test('says how many of the category are hidden', () {
      expect(hiddenInCategoryNote('Worship', hidden: 0, total: 4), isNull);
      expect(
        hiddenInCategoryNote('Worship', hidden: 4, total: 4),
        'Toate cele 4 stații din Worship sunt ascunse.',
      );
      expect(
        hiddenInCategoryNote('Worship', hidden: 1, total: 1),
        'Singura stație din Worship e ascunsă.',
      );
      expect(
        hiddenInCategoryNote('Worship', hidden: 1, total: 4),
        'O stație din Worship e ascunsă.',
      );
      expect(
        hiddenInCategoryNote('Worship', hidden: 3, total: 4),
        '3 stații din Worship sunt ascunse.',
      );
    });
  });

  test('listenersLabel counts listeners in Romanian', () {
    expect(listenersLabel(1), '1 ascultător');
    expect(listenersLabel(5), '5 ascultători');
    expect(listenersLabel(24), '24 de ascultători');
  });

  group('desktopCategoryOffer', () {
    StationGroupCategories offerOf(List<String> slugs) =>
        StationGroupCategories(
          categories: [
            for (var i = 0; i < slugs.length; i++)
              StationGroupCategory(
                group: StationFactory.createStationGroup(
                  id: i + 1,
                  name: slugs[i],
                  slug: slugs[i],
                  order: i,
                ),
                stationCount: 1,
              ),
          ],
          stationCount: 64,
          listenerCount: 500,
        );

    List<String> slugsOf(StationGroupCategories offer) =>
        [for (final c in offer.categories) c.group.slug];

    test('leads with the chosen categories, the others after in the API '
        'order, without Worship, Gospel and Colinde', () {
      // The API's order of the station groups.
      final offer = desktopCategoryOffer(offerOf([
        'general',
        'muzica',
        'emisiuni',
        'popular',
        'predici',
        'worship',
        'international',
        'gospel',
        'instrumental',
        'copii',
        'biblia',
        'colinde',
      ]));
      expect(slugsOf(offer), [
        'general',
        'muzica',
        'copii',
        'emisiuni',
        'predici',
        'biblia',
        'popular',
        'international',
        'instrumental',
      ]);
      expect(offer.stationCount, 64);
      expect(offer.listenerCount, 500);
    });

    test('skips a leading category the API does not have', () {
      final offer = desktopCategoryOffer(offerOf(['popular', 'muzica']));
      expect(slugsOf(offer), ['muzica', 'popular']);
    });
  });
}
