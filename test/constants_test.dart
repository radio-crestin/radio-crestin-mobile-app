import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/constants.dart';

void main() {
  group('CONSTANTS', () {
    test('GRAPHQL_ENDPOINT is set', () {
      expect(CONSTANTS.GRAPHQL_ENDPOINT, isNotEmpty);
      expect(CONSTANTS.GRAPHQL_ENDPOINT, contains('radiocrestin.ro'));
    });

    test('GRAPHQL_AUTH is public token', () {
      expect(CONSTANTS.GRAPHQL_AUTH, 'Token public');
    });

    test('API_BASE_URL is set', () {
      expect(CONSTANTS.API_BASE_URL, isNotEmpty);
      expect(CONSTANTS.API_BASE_URL, contains('radiocrestin.ro'));
    });

    test('STATIONS_URL is derived from API_BASE_URL', () {
      expect(CONSTANTS.STATIONS_URL, contains(CONSTANTS.API_BASE_URL));
      expect(CONSTANTS.STATIONS_URL, endsWith('/stations'));
    });

    test('STATIONS_METADATA_URL is derived from API_BASE_URL', () {
      expect(CONSTANTS.STATIONS_METADATA_URL, contains(CONSTANTS.API_BASE_URL));
      expect(CONSTANTS.STATIONS_METADATA_URL, endsWith('/stations-metadata'));
    });

    test('SHARE_LINKS_URL is derived from API_BASE_URL', () {
      expect(CONSTANTS.SHARE_LINKS_URL, contains(CONSTANTS.API_BASE_URL));
      expect(CONSTANTS.SHARE_LINKS_URL, endsWith('/share-links'));
    });

    test('STATIC_MP3_URL points to S3', () {
      expect(CONSTANTS.STATIC_MP3_URL, contains('s3'));
      expect(CONSTANTS.STATIC_MP3_URL, endsWith('.mp3'));
    });

    test('DEFAULT_STATION_THUMBNAIL_URL starts empty', () {
      expect(CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL, isEmpty);
    });

    test('IMAGE_PROXY_PREFIX starts empty', () {
      expect(CONSTANTS.IMAGE_PROXY_PREFIX, isEmpty);
    });
  });
}
