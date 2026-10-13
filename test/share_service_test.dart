import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/services/share_service.dart';

void main() {
  group('ShareLinkData', () {
    late ShareLinkData shareLinkData;

    setUp(() {
      shareLinkData = ShareLinkData(
        shareId: 'abc123',
        url: 'https://radio-crestin.com/share',
        shareMessage: 'Check out {url}',
        shareStationMessage: 'Listen to {station_name} at {url}',
        visitCount: 42,
        createdAt: '2024-01-01T00:00:00Z',
        isActive: true,
        shareSectionMessage: 'Share section message',
        shareSectionTitle: 'Share section title',
      );
    });

    test('stores all properties correctly', () {
      expect(shareLinkData.shareId, 'abc123');
      expect(shareLinkData.url, 'https://radio-crestin.com/share');
      expect(shareLinkData.shareMessage, 'Check out {url}');
      expect(shareLinkData.shareStationMessage, 'Listen to {station_name} at {url}');
      expect(shareLinkData.visitCount, 42);
      expect(shareLinkData.createdAt, '2024-01-01T00:00:00Z');
      expect(shareLinkData.isActive, true);
      expect(shareLinkData.shareSectionMessage, 'Share section message');
      expect(shareLinkData.shareSectionTitle, 'Share section title');
    });

    group('generateShareUrl', () {
      test('generates URL without station slug', () {
        final url = shareLinkData.generateShareUrl();
        expect(url, 'https://radio-crestin.com/share?s=abc123');
      });

      test('generates URL with station slug', () {
        final url = shareLinkData.generateShareUrl(stationSlug: 'radio-emanuel');
        expect(url, 'https://radio-crestin.com/share/radio-emanuel?s=abc123');
      });

      test('ignores empty station slug', () {
        final url = shareLinkData.generateShareUrl(stationSlug: '');
        expect(url, 'https://radio-crestin.com/share?s=abc123');
      });

      test('ignores null station slug', () {
        final url = shareLinkData.generateShareUrl(stationSlug: null);
        expect(url, 'https://radio-crestin.com/share?s=abc123');
      });
    });
  });

  group('ShareLinkData JSON', () {
    test('round-trips through toJson and fromJson', () {
      final data = ShareLinkData.fromJson({
        'share_id': 'abc123',
        'url': 'https://asculta.radiocrestin.ro',
        'share_message': 'm',
        'share_station_message': 'sm',
        'visit_count': 24,
        'created_at': '2026-10-13T00:00:00Z',
        'is_active': false,
        'share_section_message': 'ssm',
        'share_section_title': 'sst',
      });
      expect(ShareLinkData.fromJson(data.toJson()).toJson(), data.toJson());
      expect(data.visitCount, 24);
      expect(data.isActive, isFalse);
    });

    test('fills missing fields with defaults', () {
      final data = ShareLinkData.fromJson({'share_id': 'abc'});
      expect(data.url, '');
      expect(data.visitCount, 0);
      expect(data.isActive, isTrue);
    });
  });

  group('ShareLinkCache', () {
    tearDown(() => GetIt.instance.reset());

    Future<void> registerPrefs([Map<String, Object> values = const {}]) async {
      SharedPreferences.setMockInitialValues(values);
      GetIt.instance.registerSingleton<SharedPreferences>(
        await SharedPreferences.getInstance(),
      );
    }

    test('reads back what it saved', () async {
      await registerPrefs();
      expect(ShareLinkCache.read(), isNull);

      await ShareLinkCache.save(
        ShareLinkData.fromJson({'share_id': 'abc', 'visit_count': 7}),
      );
      final cached = ShareLinkCache.read();
      expect(cached?.shareId, 'abc');
      expect(cached?.visitCount, 7);
    });

    test('ignores an unreadable entry', () async {
      await registerPrefs({'share_link_cache': 'not json'});
      expect(ShareLinkCache.read(), isNull);
    });

    test('is empty without registered preferences', () async {
      expect(ShareLinkCache.read(), isNull);
      await ShareLinkCache.save(ShareLinkData.fromJson({'share_id': 'abc'}));
    });
  });
}
