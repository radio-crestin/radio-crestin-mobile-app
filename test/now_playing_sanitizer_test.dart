import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/now_playing_sanitizer.dart';

void main() {
  final now = DateTime.utc(2026, 10, 11, 12);

  NowPlayingVerdict verdict({
    String station = 'Radio Test',
    Duration age = const Duration(minutes: 3),
    String? song = 'Amazing Grace',
    String? artist,
  }) =>
      NowPlayingSanitizer.verdict(
        stationTitle: station,
        startedAt: now.subtract(age),
        songName: song,
        artistName: artist,
        now: now,
      );

  group('age rule (14 days)', () {
    test('the boundary', () {
      expect(verdict(age: const Duration(days: 14)), NowPlayingVerdict.keep);
      expect(verdict(age: const Duration(days: 14, seconds: 1)),
          NowPlayingVerdict.hideSong);
    });

    test('measured static titles are kept', () {
      expect(
          verdict(
              station: 'RVE Oradea Muzica',
              song: 'Cuprins am fost de uimire',
              artist: 'Corul Zorilor',
              age: const Duration(hours: 15)),
          NowPlayingVerdict.keep);
    });

    test('measured dead rows and garbage are hidden', () {
      expect(
          verdict(
              station: 'Alt FM',
              song: 'ChannelElement 3.1 missing',
              age: const Duration(hours: 924)),
          NowPlayingVerdict.hideSong);
      expect(
          verdict(
              station: 'Radio Ekklesia',
              song: 'Numai la cruce',
              artist: 'Bianca Cernisov',
              age: const Duration(days: 161)),
          NowPlayingVerdict.hideSong);
    });
  });

  group('echo rule', () {
    test('a song that only repeats the station name is hidden at any age', () {
      expect(verdict(station: 'RVE Oradea', song: 'RVE Oradea'),
          NowPlayingVerdict.hideSong);
    });

    test('an artist that only repeats the station name is dropped', () {
      expect(
          verdict(
              station: 'Radio Filadelfia Christmas',
              song: 'Colind',
              artist: 'RADIO FILADELFIA CHRISTMAS'),
          NowPlayingVerdict.dropArtist);
    });

    test('containing the station name is not an echo', () {
      expect(
          verdict(
              station: 'Radio Betel Alcala',
              song: 'Radio Betel Alcala LIVE Instrumental 2'),
          NowPlayingVerdict.keep);
      expect(
          verdict(
              station: 'Radio Calea Spre Cer Biblia',
              song: 'Radio Calea Spre Cer - Un radio pentru suflet'),
          NowPlayingVerdict.keep);
    });

    test('diacritics, case and punctuation are folded', () {
      expect(NowPlayingSanitizer.normalize('  Rădăcini—ȘI  Țărână! '),
          'radacini si tarana');
      expect(verdict(station: 'Vocea Speranței', song: 'VOCEA SPERANTEI'),
          NowPlayingVerdict.hideSong);
    });

    test('hideSong wins over dropArtist', () {
      expect(verdict(station: 'RVE', song: 'RVE', artist: 'RVE'),
          NowPlayingVerdict.hideSong);
    });
  });

  group('on-air placeholder rule', () {
    test('a song that only says LIVE is hidden at any age', () {
      expect(
          verdict(
              station: 'Radio Micul Samaritean',
              song: 'LIVE',
              artist: 'Radio Micul Samaritean'),
          NowPlayingVerdict.hideSong);
      expect(
          verdict(
              station: 'Radio Micul Samaritean',
              song: 'LIVE',
              age: const Duration(hours: 156)),
          NowPlayingVerdict.hideSong);
    });

    test('case, spaces and punctuation around it are folded', () {
      expect(verdict(song: 'live'), NowPlayingVerdict.hideSong);
      expect(verdict(song: '  Live! '), NowPlayingVerdict.hideSong);
    });

    test('a station without a title still hides it', () {
      expect(verdict(station: '', song: 'LIVE'), NowPlayingVerdict.hideSong);
    });

    test('a title that only contains LIVE is a song', () {
      expect(verdict(song: 'SO BE IT ASA VA FI, LIVE'), NowPlayingVerdict.keep);
      expect(verdict(song: 'Se apropie mereu sfarsitul LIVE'),
          NowPlayingVerdict.keep);
      expect(verdict(song: 'Lucruri noi (live) - Lucruri Noi (Live)'),
          NowPlayingVerdict.keep);
    });
  });

  group('capitalized', () {
    String cap(String text) => NowPlayingSanitizer.capitalized(text);

    test('starts a lowercase title or name with a capital letter', () {
      expect(cap('mergand pe calea vieti'), 'Mergand pe calea vieti');
      expect(cap('david dolha'), 'David dolha');
      expect(cap('ștefan și prietenii'), 'Ștefan și prietenii');
      expect(cap('copii-Arca lui Noe'), 'Copii-Arca lui Noe');
      expect(cap('fr.Aschilean - Prin lunga noastra pribegie'),
          'Fr.Aschilean - Prin lunga noastra pribegie');
    });

    test('the first letter can follow punctuation', () {
      expect(cap('(in Fata Ta)'), '(In Fata Ta)');
      expect(cap('- poate Domnul'), '- Poate Domnul');
    });

    test('keeps the rest as sent', () {
      expect(cap('Acolo nu vor fi'), 'Acolo nu vor fi');
      expect(cap('DE VORBA CU AVOCATUL'), 'DE VORBA CU AVOCATUL');
    });

    test('leaves a title that starts with a digit', () {
      expect(cap('03. dana si crina'), '03. dana si crina');
    });

    test('leaves names styled in mixed case', () {
      expect(cap('iBelieve Worship'), 'iBelieve Worship');
      expect(cap('beCLEAN'), 'beCLEAN');
      expect(cap('kL'), 'kL');
    });

    test('leaves web addresses', () {
      expect(cap('www.rvesv.ro'), 'www.rvesv.ro');
      expect(cap('(www.rvesv.ro)'), '(www.rvesv.ro)');
      expect(cap('https://radiocrestin.ro'), 'https://radiocrestin.ro');
    });

    test('leaves text without a letter or digit', () {
      expect(cap(''), '');
      expect(cap(' - '), ' - ');
    });
  });

  group('capitalize verdict', () {
    test('a lowercase song or artist is capitalized', () {
      expect(verdict(song: 'vine isus'), NowPlayingVerdict.capitalize);
      expect(verdict(artist: 'speranta si prietenii'),
          NowPlayingVerdict.capitalize);
    });

    test('a capitalized song is kept; a station without a title capitalizes',
        () {
      expect(verdict(artist: 'Speranta'), NowPlayingVerdict.keep);
      expect(verdict(station: '', song: 'vine isus'),
          NowPlayingVerdict.capitalize);
    });

    test('hiding wins over capitalizing', () {
      expect(
          verdict(song: 'vine isus', age: const Duration(days: 15)),
          NowPlayingVerdict.hideSong);
      expect(verdict(station: 'RVE Oradea', song: 'rve oradea'),
          NowPlayingVerdict.hideSong);
    });
  });

  test('a fresh, ordinary row is kept; no song is kept', () {
    expect(verdict(artist: 'Hristic'), NowPlayingVerdict.keep);
    expect(verdict(song: null), NowPlayingVerdict.keep);
  });

  group('apply', () {
    Map<String, dynamic> stationJson() => {
          'id': 1,
          'title': 'RVE Oradea',
          'total_listeners': 12,
          'now_playing': {
            'id': 3,
            'timestamp': '2026-04-14T10:00:00Z',
            'song': {
              'id': 5,
              'name': 'RVE Oradea',
              'artist': {'id': 2, 'name': 'X'},
            },
          },
        };

    test('hideSong removes the song, keeps timestamp and listeners', () {
      final out =
          NowPlayingSanitizer.apply(stationJson(), NowPlayingVerdict.hideSong);
      expect(out['now_playing']['song'], isNull);
      expect(out['now_playing']['timestamp'], '2026-04-14T10:00:00Z');
      expect(out['total_listeners'], 12);
    });

    test('dropArtist removes only the artist', () {
      final out = NowPlayingSanitizer.apply(
          stationJson(), NowPlayingVerdict.dropArtist);
      expect(out['now_playing']['song']['name'], 'RVE Oradea');
      expect(out['now_playing']['song']['artist'], isNull);
    });

    Map<String, dynamic> lowercaseJson({Object? artist}) => {
          'id': 1,
          'title': 'Radio Test',
          'now_playing': {
            'id': 3,
            'timestamp': '2026-04-14T10:00:00Z',
            'song': {
              'id': 5,
              'name': 'vine isus',
              'thumbnail_url': 'https://x/song.jpg',
              'artist': artist,
            },
          },
        };

    test('capitalize capitalizes the song and artist, keeps the rest', () {
      final out = NowPlayingSanitizer.apply(
          lowercaseJson(artist: {'id': 2, 'name': 'biji din barbulesti'}),
          NowPlayingVerdict.capitalize);
      final song = out['now_playing']['song'];
      expect(song['name'], 'Vine isus');
      expect(song['id'], 5);
      expect(song['thumbnail_url'], 'https://x/song.jpg');
      expect(song['artist'], {'id': 2, 'name': 'Biji din barbulesti'});
      expect(out['now_playing']['timestamp'], '2026-04-14T10:00:00Z');
    });

    test('capitalize keeps a missing artist missing', () {
      final out = NowPlayingSanitizer.apply(
          lowercaseJson(), NowPlayingVerdict.capitalize);
      expect(out['now_playing']['song']['name'], 'Vine isus');
      expect(out['now_playing']['song']['artist'], isNull);
    });

    test('dropArtist capitalizes the song it keeps', () {
      final out = NowPlayingSanitizer.apply(
          lowercaseJson(artist: {'id': 2, 'name': 'Radio Test'}),
          NowPlayingVerdict.dropArtist);
      expect(out['now_playing']['song']['name'], 'Vine isus');
      expect(out['now_playing']['song']['artist'], isNull);
    });

    test('keep and a missing now_playing return the input', () {
      final json = stationJson();
      expect(
          NowPlayingSanitizer.apply(json, NowPlayingVerdict.keep), same(json));
      final bare = {'id': 1};
      expect(NowPlayingSanitizer.apply(bare, NowPlayingVerdict.hideSong),
          same(bare));
    });
  });
}
