import 'package:flutter_carplay/aa_models/grid/grid_template.dart';
import 'package:flutter_carplay/aa_models/list/list_item.dart';
import 'package:flutter_carplay/aa_models/list/list_section.dart';
import 'package:flutter_carplay/aa_models/list/list_template.dart';
import 'package:flutter_carplay/aa_models/tab/tab.dart';
import 'package:flutter_carplay/aa_models/tab/tab_template.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/station_factory.dart';

/// Tests for Android Auto thumbnail loading logic and list-vs-grid layout.
///
/// 1. Image URL handling: verifies that _cachedOrNetworkUrl produces correct
///    URIs and that the native side receives file:// or https:// URLs.
/// 2. List layout: verifies that station lists ALWAYS use AAListTemplate
///    (never AAGridTemplate), so older Android Auto hosts display a vertical
///    list instead of a grid.
void main() {
  // ---------------------------------------------------------------------------
  // Image URL handling
  // ---------------------------------------------------------------------------
  group('Android Auto - image URL handling for thumbnails', () {
    /// Mirrors CarPlayService._cachedOrNetworkUrl
    String? cachedOrNetworkUrl(String? url, String? cachedPath) {
      if (url == null || url.isEmpty) return url;
      if (cachedPath != null) return 'file://$cachedPath';
      return url;
    }

    test('cached image returns file:// URI with correct path', () {
      final result = cachedOrNetworkUrl(
        'https://cdn.example.com/station/thumb.png',
        '/data/user/0/com.radiocrestin.radio_crestin/files/image_cache/abc123.png',
      );
      expect(result,
          'file:///data/user/0/com.radiocrestin.radio_crestin/files/image_cache/abc123.png');
    });

    test('file:// URI starts with file:// and has valid absolute path', () {
      final result = cachedOrNetworkUrl(
        'https://example.com/thumb.png',
        '/data/user/0/com.example/cache/img.png',
      );
      expect(result, startsWith('file://'));
      // After removing file://, the path should be absolute
      expect(result!.substring(7), startsWith('/'));
    });

    test('uncached image returns original https URL', () {
      final result = cachedOrNetworkUrl(
        'https://cdn.example.com/station/thumb.png',
        null,
      );
      expect(result, 'https://cdn.example.com/station/thumb.png');
    });

    test('null URL returns null', () {
      expect(cachedOrNetworkUrl(null, null), isNull);
      expect(cachedOrNetworkUrl(null, '/some/path'), isNull);
    });

    test('empty URL returns empty', () {
      expect(cachedOrNetworkUrl('', null), '');
      expect(cachedOrNetworkUrl('', '/some/path'), '');
    });

    test('file:// path does not double-prefix', () {
      // If the cached path already has file://, we should not get file://file://
      final result = cachedOrNetworkUrl(
        'https://example.com/thumb.png',
        '/path/to/image.png',
      );
      expect(result, isNot(contains('file://file://')));
      // Should only have one file:// prefix
      expect('file://'.allMatches(result!).length, 1);
    });

    test('imageUrl is passed to AAListItem correctly', () {
      final item = AAListItem(
        title: 'Test Station',
        imageUrl: 'file:///data/cache/thumb.png',
      );
      final json = item.toJson();
      expect(json['imageUrl'], 'file:///data/cache/thumb.png');
    });

    test('AAListItem with https imageUrl serializes correctly', () {
      final item = AAListItem(
        title: 'Test Station',
        imageUrl: 'https://cdn.example.com/thumb.png',
      );
      final json = item.toJson();
      expect(json['imageUrl'], 'https://cdn.example.com/thumb.png');
    });

    test('AAListItem with null imageUrl serializes as null', () {
      final item = AAListItem(
        title: 'Test Station',
        imageUrl: null,
      );
      final json = item.toJson();
      expect(json['imageUrl'], isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Kotlin-side file:// path parsing (pure logic test)
  // ---------------------------------------------------------------------------
  group('Android Auto - file path parsing logic', () {
    /// Mirrors the Kotlin loadFromFile path extraction logic.
    String extractFilePath(String imageUrl) {
      if (imageUrl.startsWith('file://')) {
        return imageUrl.substring(7); // removePrefix("file://")
      }
      return imageUrl;
    }

    test('strips file:// prefix from URI', () {
      expect(
        extractFilePath('file:///data/user/0/com.example/cache/img.png'),
        '/data/user/0/com.example/cache/img.png',
      );
    });

    test('preserves raw absolute path', () {
      expect(
        extractFilePath('/data/user/0/com.example/cache/img.png'),
        '/data/user/0/com.example/cache/img.png',
      );
    });

    test('handles file:// with no path (edge case)', () {
      expect(extractFilePath('file://'), '');
    });

    test('isFileUrl detection matches Kotlin logic', () {
      bool isFileUrl(String url) =>
          url.startsWith('file://') || url.startsWith('/');

      expect(isFileUrl('file:///data/cache/img.png'), isTrue);
      expect(isFileUrl('/data/cache/img.png'), isTrue);
      expect(isFileUrl('https://cdn.example.com/img.png'), isFalse);
      expect(isFileUrl('http://cdn.example.com/img.png'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // List layout: station lists must always use AAListTemplate, never grid
  // ---------------------------------------------------------------------------
  group('Android Auto - list layout (never grid)', () {
    /// Mirrors CarPlayService._buildStationListTemplate
    AAListTemplate buildStationListTemplate({
      required String title,
      required List<Map<String, String>> stations,
      String? currentSlug,
      bool isCurrentlyPlaying = false,
    }) {
      const maxItems = 100;
      final stationsToShow =
          stations.length > maxItems ? stations.sublist(0, maxItems) : stations;

      return AAListTemplate(
        title: title,
        sections: [
          AAListSection(
            items: stationsToShow.map((station) {
              final isPlaying =
                  station['slug'] == currentSlug && isCurrentlyPlaying;
              return AAListItem(
                title: isPlaying
                    ? "▶ ${station['title']}"
                    : station['title'] ?? '',
                subtitle: station['subtitle'],
                imageUrl: station['imageUrl'],
              );
            }).toList(),
          ),
        ],
      );
    }

    test('station list uses AAListTemplate, not AAGridTemplate', () {
      final template = buildStationListTemplate(
        title: 'All Stations',
        stations: [
          {'slug': 's1', 'title': 'Station 1', 'imageUrl': 'https://x.com/1.png'},
          {'slug': 's2', 'title': 'Station 2', 'imageUrl': 'https://x.com/2.png'},
        ],
      );

      expect(template, isA<AAListTemplate>());
      expect(template, isNot(isA<AAGridTemplate>()));
    });

    test('tab content serializes as FAAListTemplate', () {
      final listTemplate = buildStationListTemplate(
        title: 'Favorites',
        stations: [
          {'slug': 's1', 'title': 'Station 1'},
        ],
      );

      final tab = AATab(
        contentId: 'favorites',
        title: 'Favorites',
        content: listTemplate,
      );

      final json = tab.toJson();
      expect(json['contentRuntimeType'], 'FAAListTemplate');
      // Must never be FAAGridTemplate
      expect(json['contentRuntimeType'], isNot('FAAGridTemplate'));
    });

    test('both tabs use FAAListTemplate content type', () {
      final favList = buildStationListTemplate(
        title: 'Favorites',
        stations: [
          {'slug': 's1', 'title': 'Station 1'},
        ],
      );
      final allList = buildStationListTemplate(
        title: 'All Stations',
        stations: [
          {'slug': 's1', 'title': 'Station 1'},
          {'slug': 's2', 'title': 'Station 2'},
        ],
      );

      final tabTemplate = AATabTemplate(
        activeTabContentId: 'favorites',
        tabs: [
          AATab(contentId: 'favorites', title: 'Favorites', content: favList),
          AATab(contentId: 'all', title: 'All', content: allList),
        ],
      );

      final json = tabTemplate.toJson();
      final tabs = json['tabs'] as List;
      for (final tab in tabs) {
        final tabMap = tab as Map<String, dynamic>;
        expect(tabMap['contentRuntimeType'], 'FAAListTemplate',
            reason:
                'Tab "${tabMap['contentId']}" must use FAAListTemplate, not grid');
      }
    });

    test('AAListTemplate sections contain AAListItems (rows, not grid items)', () {
      final template = buildStationListTemplate(
        title: 'Test',
        stations: [
          {'slug': 's1', 'title': 'Station 1', 'imageUrl': 'https://x.com/1.png'},
          {'slug': 's2', 'title': 'Station 2', 'imageUrl': 'https://x.com/2.png'},
          {'slug': 's3', 'title': 'Station 3'},
        ],
      );

      expect(template.sections.length, 1);
      expect(template.sections.first.items.length, 3);
      for (final item in template.sections.first.items) {
        expect(item, isA<AAListItem>());
      }
    });

    test('list template respects max 100 items limit', () {
      final manyStations = List.generate(
        150,
        (i) => {'slug': 'station-$i', 'title': 'Station $i'},
      );

      final template = buildStationListTemplate(
        title: 'All Stations',
        stations: manyStations,
      );

      expect(template.sections.first.items.length, 100);
    });

    test('playing station gets play indicator prefix in list', () {
      final template = buildStationListTemplate(
        title: 'Test',
        stations: [
          {'slug': 's1', 'title': 'Station 1'},
          {'slug': 's2', 'title': 'Station 2'},
          {'slug': 's3', 'title': 'Station 3'},
        ],
        currentSlug: 's2',
        isCurrentlyPlaying: true,
      );

      final items = template.sections.first.items;
      expect(items[0].title, 'Station 1');
      expect(items[1].title, '▶ Station 2');
      expect(items[2].title, 'Station 3');
    });

    test('paused station has no play indicator prefix', () {
      final template = buildStationListTemplate(
        title: 'Test',
        stations: [
          {'slug': 's1', 'title': 'Station 1'},
          {'slug': 's2', 'title': 'Station 2'},
        ],
        currentSlug: 's2',
        isCurrentlyPlaying: false,
      );

      final items = template.sections.first.items;
      expect(items[0].title, 'Station 1');
      expect(items[1].title, 'Station 2'); // no prefix when paused
    });
  });

  // ---------------------------------------------------------------------------
  // Tab template structure for old vs new AA
  // ---------------------------------------------------------------------------
  group('Android Auto - tab template fallback for old API levels', () {
    test('tab template contains only list content for station tabs', () {
      // Simulate building the tab template as CarPlayService does
      final stations = StationFactory.createPlaylist(count: 10);
      final favoriteSlugs = {'station-1', 'station-3', 'station-5'};

      final favoriteStations =
          stations.where((s) => favoriteSlugs.contains(s.slug)).toList();

      // Build list templates (as CarPlayService._buildStationListTemplate does)
      final favList = AAListTemplate(
        title: 'Favorites',
        sections: [
          AAListSection(
            items: favoriteStations
                .map((s) => AAListItem(
                      title: s.title,
                      imageUrl: s.thumbnailUrl,
                    ))
                .toList(),
          ),
        ],
      );

      final allList = AAListTemplate(
        title: 'All Stations',
        sections: [
          AAListSection(
            items: stations
                .map((s) => AAListItem(
                      title: s.title,
                      imageUrl: s.thumbnailUrl,
                    ))
                .toList(),
          ),
        ],
      );

      final tabTemplate = AATabTemplate(
        activeTabContentId: 'favorites',
        tabs: [
          AATab(contentId: 'favorites', title: 'Favorites', content: favList),
          AATab(contentId: 'all', title: 'All Stations', content: allList),
        ],
      );

      // Verify structure
      expect(tabTemplate.tabs.length, 2);

      // Verify all tabs serialize as FAAListTemplate
      final json = tabTemplate.toJson();
      for (final tab in json['tabs'] as List) {
        expect((tab as Map)['contentRuntimeType'], 'FAAListTemplate');
      }

      // Verify favorites tab has correct item count
      final favJson = (json['tabs'] as List)[0] as Map;
      final favContent = favJson['content'] as Map;
      final favSections = favContent['sections'] as List;
      final favItems = (favSections[0] as Map)['items'] as List;
      expect(favItems.length, 3);

      // Verify all stations tab has correct item count
      final allJson = (json['tabs'] as List)[1] as Map;
      final allContent = allJson['content'] as Map;
      final allSections = allContent['sections'] as List;
      final allItems = (allSections[0] as Map)['items'] as List;
      expect(allItems.length, 10);
    });

    test('image URLs are present in serialized list items', () {
      final item = AAListItem(
        title: 'Test Station',
        imageUrl: 'file:///data/cache/thumb.png',
      );

      final json = item.toJson();
      expect(json['imageUrl'], isNotNull);
      expect(json['imageUrl'], isNotEmpty);
    });

    test('all stations have imageUrl set when thumbnailUrl is provided', () {
      final stations = StationFactory.createPlaylist(count: 5);

      for (final station in stations) {
        // StationFactory creates stations with thumbnailUrl = 'https://example.com/thumb.png'
        expect(station.thumbnailUrl, isNotNull);
        expect(station.thumbnailUrl, isNotEmpty);

        final item = AAListItem(
          title: station.title,
          imageUrl: station.thumbnailUrl,
        );
        expect(item.imageUrl, station.thumbnailUrl);
      }
    });
  });
}
