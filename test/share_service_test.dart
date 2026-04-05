import 'package:flutter_test/flutter_test.dart';

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
}
