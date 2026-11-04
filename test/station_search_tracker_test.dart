import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/station_search_tracker.dart';

void main() {
  late List<Map<String, Object?>> recorded;
  late StationSearchCounts counts;

  StationSearchTracker tracker() => StationSearchTracker(
        source: 'mobile',
        countsFor: (_) => counts,
        capture: (event, properties) {
          expect(event, 'station_searched');
          recorded.add(properties);
        },
      );

  setUp(() {
    recorded = [];
    counts = (byName: 2, bySong: 1);
  });

  test('records the query typing settles on, not every keystroke', () {
    fakeAsync((async) {
      final search = tracker();
      for (final text in ['c', 'cl', 'clu', 'cluj ']) {
        search.queryChanged(text);
        async.elapse(const Duration(milliseconds: 300));
      }
      expect(recorded, isEmpty);

      async.elapse(const Duration(milliseconds: 1500));

      expect(recorded, [
        {
          'query': 'cluj',
          'query_normalized': 'cluj',
          'results_count': 3,
          'name_results_count': 2,
          'song_results_count': 1,
          'has_results': true,
          'source': 'mobile',
        },
      ]);
    });
  });

  test('marks a search that finds nothing', () {
    fakeAsync((async) {
      counts = (byName: 0, bySong: 0);
      tracker().queryChanged('Radio Inexistent');
      async.elapse(const Duration(seconds: 2));

      expect(recorded.single['has_results'], isFalse);
      expect(recorded.single['results_count'], 0);
      expect(recorded.single['query_normalized'], 'radio inexistent');
    });
  });

  test('flush records the settling query at once, only once', () {
    fakeAsync((async) {
      final search = tracker()..queryChanged('betel');
      search.flush();
      expect(recorded.single['query'], 'betel');

      async.elapse(const Duration(seconds: 2));
      search.flush();
      expect(recorded, hasLength(1));
    });
  });

  test('clearing the field records what was typed before it', () {
    fakeAsync((async) {
      tracker()
        ..queryChanged('aripi')
        ..queryChanged('');
      expect(recorded.single['query'], 'aripi');
    });
  });

  test('the same query is not recorded twice in a row in one search', () {
    fakeAsync((async) {
      final search = tracker()..queryChanged('Cluj');
      async.elapse(const Duration(seconds: 2));
      search.queryChanged('cluj ');
      async.elapse(const Duration(seconds: 2));
      expect(recorded, hasLength(1));
    });
  });

  test('a new search may record the same query again', () {
    fakeAsync((async) {
      final search = tracker()..queryChanged('cluj');
      async.elapse(const Duration(seconds: 2));
      search
        ..queryChanged('')
        ..queryChanged('cluj');
      async.elapse(const Duration(seconds: 2));
      expect(recorded, hasLength(2));
    });
  });
}
