import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/utils/share_utils.dart';

void main() {
  group('ShareUtils', () {
    late ShareLinkData shareLinkData;

    setUp(() {
      shareLinkData = ShareLinkData(
        shareId: 'abc123',
        url: 'https://radio-crestin.com/share',
        shareMessage: 'Ascultă radio creștin la {url}',
        shareStationMessage: 'Ascultă {station_name} la {url}',
        visitCount: 10,
        createdAt: '2024-01-01',
        isActive: true,
        shareSectionMessage: '',
        shareSectionTitle: '',
      );
    });

    group('formatShareMessage', () {
      test('uses shareStationMessage when stationName is provided', () {
        final message = ShareUtils.formatShareMessage(
          shareLinkData: shareLinkData,
          stationName: 'Radio Emanuel',
          stationSlug: 'radio-emanuel',
        );
        expect(message, contains('Radio Emanuel'));
        expect(message, contains('radio-crestin.com/share/radio-emanuel'));
      });

      test('uses shareMessage when no stationName', () {
        final message = ShareUtils.formatShareMessage(
          shareLinkData: shareLinkData,
          stationName: null,
          stationSlug: null,
        );
        expect(message, contains('Ascultă radio creștin'));
        expect(message, contains('radio-crestin.com/share'));
      });

      test('falls back to default message when shareMessage is empty', () {
        final emptyData = ShareLinkData(
          shareId: 'abc',
          url: 'https://radio-crestin.com/share',
          shareMessage: '',
          shareStationMessage: '',
          visitCount: 0,
          createdAt: '',
          isActive: true,
          shareSectionMessage: '',
          shareSectionTitle: '',
        );

        final message = ShareUtils.formatShareMessage(
          shareLinkData: emptyData,
          stationName: null,
        );
        expect(message, contains('Ascultă posturile de radio creștine'));
        expect(message, contains('radio-crestin.com/share'));
      });

      test('replaces {url} placeholder in shareStationMessage', () {
        final message = ShareUtils.formatShareMessage(
          shareLinkData: shareLinkData,
          stationName: 'Test',
          stationSlug: 'test-slug',
        );
        expect(message, isNot(contains('{url}')));
        expect(message, contains('?s=abc123'));
      });

      test('replaces {station_name} placeholder', () {
        final message = ShareUtils.formatShareMessage(
          shareLinkData: shareLinkData,
          stationName: 'Radio Vocea',
          stationSlug: null,
        );
        expect(message, isNot(contains('{station_name}')));
        expect(message, contains('Radio Vocea'));
      });
    });

    group('combineMessageWithUrl', () {
      test('appends URL if not already in message', () {
        final result = ShareUtils.combineMessageWithUrl(
          'Hello world',
          'https://example.com',
        );
        expect(result, 'Hello world\nhttps://example.com');
      });

      test('does not duplicate URL if already present', () {
        final result = ShareUtils.combineMessageWithUrl(
          'Visit https://example.com today',
          'https://example.com',
        );
        expect(result, 'Visit https://example.com today');
      });
    });

    group('formatMessageWithStation', () {
      test('appends station name and URL when not in message', () {
        final result = ShareUtils.formatMessageWithStation(
          'Check this out',
          'https://example.com',
          'Radio Emanuel',
        );
        expect(result, contains('Ascultă acum: Radio Emanuel'));
        expect(result, contains('https://example.com'));
      });

      test('appends station name when URL already in message', () {
        final result = ShareUtils.formatMessageWithStation(
          'Visit https://example.com',
          'https://example.com',
          'Radio Emanuel',
        );
        expect(result, contains('Ascultă acum: Radio Emanuel'));
        // URL should not be duplicated at the end
        expect(result, 'Visit https://example.com\n\nAscultă acum: Radio Emanuel');
      });

      test('falls back to combineMessageWithUrl when stationName is null', () {
        final result = ShareUtils.formatMessageWithStation(
          'Hello',
          'https://example.com',
          null,
        );
        expect(result, 'Hello\nhttps://example.com');
      });
    });
  });
}
