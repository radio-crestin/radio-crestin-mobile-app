import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/station_voice_search.dart';

/// The catalog's station names on 2026-10-18.
const _titles = [
  'Aripi Spre Cer',
  'Aripi Spre Cer Instrumental',
  'Aripi Spre Cer Popular',
  'Aripi Spre Cer Predici',
  'Aripi Spre Cer Special',
  'Calea Spre Cer Biblia',
  'Calea Spre Cer Copii',
  'Calea Spre Cer Popular',
  'Cross One',
  'RVE Brasov',
  'RVE Bucuresti',
  'RVE Cluj',
  'RVE Constanta',
  'RVE Hunedoara',
  'RVE Oradea',
  'RVE Oradea International',
  'RVE Oradea Muzica',
  'RVE Predici',
  'RVE Satu Mare',
  'RVE Sibiu',
  'RVE Soveja',
  'RVE Suceava',
  'RVE Targoviste',
  'RVE Timisoara',
  'RVE Viena',
  'RVE Viena Muzica',
  'RVE Viena Tineri [DE]',
  'RVE Zalau',
  'Radio 9 FM - Moldova Noua',
  'Radio ALT FM Arad',
  'Radio Allelon',
  'Radio Antiohia',
  'Radio Armonia',
  'Radio Betel Alcala',
  'Radio Calea Spre Cer',
  'Radio Crestin Autentic',
  'Radio Ekklesia',
  'Radio Eldad',
  'Radio Elim Air',
  'Radio Elim Kids',
  'Radio Elim Plus',
  'Radio Emanuel',
  'Radio Filadelfia',
  'Radio Filadelfia Christmas',
  'Radio Filadelfia Special',
  'Radio Gosen',
  'Radio Joy',
  'Radio Levi',
  'Radio Micul Samaritean',
  'Radio Moody Chicago',
  'Radio O Noua Sansa',
  'Radio Old Christian Radio',
  'Radio Pentinădlac',
  'Radio Philadelphia Clasic',
  'Radio Philadelphia Copii',
  'Radio Philadelphia Mansuè',
  'Radio Philadelphia Melbourne',
  'Radio Predic',
  'Radio SOS',
  'Radio Vestea Buna',
  'Radio Vocea Credintei',
  'Radio Vocea Creștinilor',
  'Radio Vocea Sperantei',
  'Radio de Cuvant',
];

String? _match(String spoken) {
  final index = StationVoiceSearch.bestMatch(_titles, spoken);
  return index == null ? null : _titles[index];
}

void main() {
  group('StationVoiceSearch.bestMatch', () {
    test('finds a name as written', () {
      expect(_match('RVE Constanta'), 'RVE Constanta');
      expect(_match('Aripi spre cer'), 'Aripi Spre Cer');
      expect(
          _match('aripi spre cer instrumental'), 'Aripi Spre Cer Instrumental');
      expect(_match('philadelphia melbourne'), 'Radio Philadelphia Melbourne');
    });

    test('finds a name without "Radio" or diacritics', () {
      expect(_match('joy'), 'Radio Joy');
      expect(_match('vocea crestinilor'), 'Radio Vocea Creștinilor');
      expect(_match('pentinadlac'), 'Radio Pentinădlac');
    });

    test('joins letters spelled out by speech recognition', () {
      expect(_match('R V E Constanta'), 'RVE Constanta');
      expect(_match('r v e brasov'), 'RVE Brasov');
    });

    test('forgives a name heard slightly off', () {
      expect(_match('RV constant a'), 'RVE Constanta');
      expect(_match('rve constanza'), 'RVE Constanta');
      expect(_match('rve timishoara'), 'RVE Timisoara');
      expect(_match('Emmanuel'), 'Radio Emanuel');
      expect(_match('bethel'), 'Radio Betel Alcala');
      expect(_match('goshen'), 'Radio Gosen');
      expect(_match('ecclesia'), 'Radio Ekklesia');
    });

    test('tells "RVE" stations apart by their city', () {
      expect(_match('rve bucharest'), 'RVE Bucuresti');
      expect(_match('rve oradea'), 'RVE Oradea');
      expect(_match('oradea muzica'), 'RVE Oradea Muzica');
      expect(_match('RVE predici'), 'RVE Predici');
    });

    test('knows "RVE" stands for Radio Vocea Evangheliei', () {
      expect(_match('Radio Vocea Evangheliei Cluj'), 'RVE Cluj');
      expect(_match('vocea evangheliei timisoara'), 'RVE Timisoara');
    });

    test('prefers the name closest to the whole request', () {
      expect(_match('Filadelfia'), 'Radio Filadelfia');
      expect(_match('filadelfia special'), 'Radio Filadelfia Special');
      expect(_match('calea spre cer'), 'Radio Calea Spre Cer');
      expect(_match('RVE Viena tineri'), 'RVE Viena Tineri [DE]');
    });

    test('matches nothing for a request that names no station', () {
      expect(_match('Taylor Swift'), isNull);
      expect(_match('news'), isNull);
      expect(_match('jazz'), isNull);
    });

    test('matches nothing for an empty request', () {
      expect(_match(''), isNull);
      expect(_match('Radio'), isNull);
    });

    test('ignores "station" said around a name', () {
      expect(_match('RVE Constanta station'), 'RVE Constanta');
      expect(_match('statia RVE Cluj'), 'RVE Cluj');
      expect(_match('postul Radio Joy'), 'Radio Joy');
    });
  });

  group('StationVoiceSearch.spokenForms', () {
    test('adds the network name to an "RVE" station', () {
      expect(StationVoiceSearch.spokenForms('RVE Constanta'),
          ['RVE Constanta', 'Radio Vocea Evangheliei Constanta']);
    });

    test('keeps other names as written', () {
      expect(StationVoiceSearch.spokenForms('Radio Pentinădlac'),
          ['Radio Pentinădlac']);
      expect(StationVoiceSearch.spokenForms('Radio Levi'), ['Radio Levi']);
    });
  });

  group('StationVoiceSearch.asksForFavorites', () {
    test('knows a request for the favorites', () {
      for (final spoken in [
        'my favorites',
        'My Favourites',
        'favorite',
        'favoritele mele',
      ]) {
        expect(StationVoiceSearch.asksForFavorites(spoken), isTrue,
            reason: spoken);
      }
    });

    test('tells a station name apart from the favorites', () {
      expect(StationVoiceSearch.asksForFavorites('RVE Constanta'), isFalse);
      expect(StationVoiceSearch.asksForFavorites('Radio Filadelfia'), isFalse);
      expect(StationVoiceSearch.asksForFavorites(''), isFalse);
    });
  });
}
