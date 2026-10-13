import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/utils/share_utils.dart';
import 'package:radio_crestin/services/share_service.dart';

void main() {
  group('ShareUtils.formatMessageWithStation', () {
    test('includes station, song name and artist in parentheses', () {
      final result = ShareUtils.formatMessageWithStation(
        'Aplicația Radio Creștin:',
        'https://www.radiocrestin.ro/radio-vocea-evangheliei?s=abc',
        'Radio Vocea Evangheliei',
        songName: 'Doamne al meu',
        songArtist: 'Grup Vocea Evangheliei',
      );
      expect(
        result,
        'Te invit să asculți Radio Vocea Evangheliei (Doamne al meu • Grup Vocea Evangheliei):\nhttps://www.radiocrestin.ro/radio-vocea-evangheliei?s=abc',
      );
    });

    test('includes station and song name without artist', () {
      final result = ShareUtils.formatMessageWithStation(
        'msg',
        'https://example.com',
        'Radio Trinitas',
        songName: 'Psalmul 23',
      );
      expect(
        result,
        'Te invit să asculți Radio Trinitas (Psalmul 23):\nhttps://example.com',
      );
    });

    test('includes station and artist without song name', () {
      final result = ShareUtils.formatMessageWithStation(
        'msg',
        'https://example.com',
        'Radio Trinitas',
        songArtist: 'Corul Madrigal',
      );
      expect(
        result,
        'Te invit să asculți Radio Trinitas (Corul Madrigal):\nhttps://example.com',
      );
    });

    test('station only, no song info — colon after station name', () {
      final result = ShareUtils.formatMessageWithStation(
        'msg',
        'https://example.com',
        'Radio Trinitas',
      );
      expect(
        result,
        'Te invit să asculți Radio Trinitas:\nhttps://example.com',
      );
    });

    test('no station falls back to message + url', () {
      final result = ShareUtils.formatMessageWithStation(
        'Aplicația Radio Creștin:',
        'https://example.com',
        null,
        songName: 'SomeSong',
      );
      expect(result, 'Aplicația Radio Creștin:\nhttps://example.com');
    });

    test('ignores empty song name and artist', () {
      final result = ShareUtils.formatMessageWithStation(
        'msg',
        'https://example.com',
        'Station',
        songName: '',
        songArtist: '',
      );
      expect(result, 'Te invit să asculți Station:\nhttps://example.com');
    });
  });

  group('ShareLinkData.generateShareUrl', () {
    final data = ShareLinkData(
      shareId: 'abc123',
      url: 'https://www.radiocrestin.ro',
      shareMessage: '',
      shareStationMessage: '',
      visitCount: 5,
      createdAt: '',
      isActive: true,
      shareSectionMessage: '',
      shareSectionTitle: '',
    );

    test('generates base url with share param', () {
      expect(
        data.generateShareUrl(),
        'https://www.radiocrestin.ro?s=abc123',
      );
    });

    test('includes station slug', () {
      expect(
        data.generateShareUrl(stationSlug: 'radio-vocea'),
        'https://www.radiocrestin.ro/radio-vocea?s=abc123',
      );
    });

    test('includes song id', () {
      expect(
        data.generateShareUrl(songId: 42),
        'https://www.radiocrestin.ro?s=abc123&song=42',
      );
    });

    test('includes station slug and song id', () {
      expect(
        data.generateShareUrl(stationSlug: 'radio-vocea', songId: 42),
        'https://www.radiocrestin.ro/radio-vocea?s=abc123&song=42',
      );
    });

    test('ignores songId <= 0', () {
      expect(
        data.generateShareUrl(songId: 0),
        'https://www.radiocrestin.ro?s=abc123',
      );
      expect(
        data.generateShareUrl(songId: -1),
        'https://www.radiocrestin.ro?s=abc123',
      );
    });
  });

  group('ShareUtils.visitCountText', () {
    test('nobody yet', () {
      expect(
        ShareUtils.visitCountText(0),
        'Niciun prieten n-a deschis încă invitația ta',
      );
    });

    test('one friend', () {
      expect(
        ShareUtils.visitCountText(1),
        'Un prieten a deschis invitația ta',
      );
    });

    test('under 20 takes no "de"', () {
      expect(
        ShareUtils.visitCountText(19),
        '19 prieteni au deschis invitația ta',
      );
    });

    test('20 and up take "de"', () {
      expect(
        ShareUtils.visitCountText(24),
        '24 de prieteni au deschis invitația ta',
      );
      expect(
        ShareUtils.visitCountText(100),
        '100 de prieteni au deschis invitația ta',
      );
    });

    test('last two digits 01–19 drop "de" again', () {
      expect(
        ShareUtils.visitCountText(101),
        '101 prieteni au deschis invitația ta',
      );
      expect(
        ShareUtils.visitCountText(119),
        '119 prieteni au deschis invitația ta',
      );
      expect(
        ShareUtils.visitCountText(120),
        '120 de prieteni au deschis invitația ta',
      );
    });
  });

  group('ShareUtils.visitCountParts', () {
    test('nobody yet has nothing to highlight', () {
      expect(ShareUtils.visitCountParts(0), isNull);
    });

    test('splits who opened it from the rest', () {
      expect(
        ShareUtils.visitCountParts(1),
        ('Un prieten', ' a deschis invitația ta'),
      );
      expect(
        ShareUtils.visitCountParts(7),
        ('7 prieteni', ' au deschis invitația ta'),
      );
      expect(
        ShareUtils.visitCountParts(24),
        ('24 de prieteni', ' au deschis invitația ta'),
      );
    });
  });
}
