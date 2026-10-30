import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/tv/desktop/desktop_play_history.dart';

void main() {
  bool any(String _) => true;

  test('back plays the stations played before, forward the ones back left',
      () {
    final history = DesktopPlayHistory()
      ..played('a')
      ..played('b')
      ..played('c');

    expect(history.back(playable: any), 'b');
    // Played as asked: nothing changes.
    history.played('b');
    expect(history.back(playable: any), 'a');
    expect(history.back(playable: any), isNull);
    expect(history.forward(playable: any), 'b');
    expect(history.forward(playable: any), 'c');
    expect(history.forward(playable: any), isNull);
  });

  test('a station started otherwise forgets what forward would play', () {
    final history = DesktopPlayHistory()
      ..played('a')
      ..played('b');
    expect(history.back(playable: any), 'a');

    history.played('c');
    expect(history.forward(playable: any), isNull);
    expect(history.back(playable: any), 'a');
  });

  test('back passes over the stations that can\'t be played now', () {
    final history = DesktopPlayHistory()
      ..played('a')
      ..played('hidden')
      ..played('c');

    expect(history.back(playable: (slug) => slug != 'hidden'), 'a');
    expect(history.forward(playable: any), 'c');
  });

  test('back reaches the stations played before the launch', () {
    // The one playing at launch was the last one played.
    final history = DesktopPlayHistory(earlier: ['a', 'b'])..played('b');

    expect(history.back(playable: any), 'a');
    expect(history.forward(playable: any), 'b');
  });

  test('back remembers only so many', () {
    final history = DesktopPlayHistory();
    for (var i = 0; i <= DesktopPlayHistory.capacity + 5; i++) {
      history.played('$i');
    }
    var steps = 0;
    while (history.back(playable: any) != null) {
      steps++;
    }
    expect(steps, DesktopPlayHistory.capacity);
  });
}
