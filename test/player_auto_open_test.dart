import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/pages/HomePage.dart';

/// Unit tests for [shouldAutoOpenPlayerPanel] — the pure rule that decides
/// whether the full player auto-opens when video / YouTube content starts.
void main() {
  group('shouldAutoOpenPlayerPanel', () {
    test('opens on the transition into content while collapsed', () {
      expect(
        shouldAutoOpenPlayerPanel(
          contentStarting: true,
          currentKey: 'yt-1',
          suppressedKey: null,
          panelClosed: true,
        ),
        isTrue,
      );
    });

    test('does not open when content is not starting (only true transitions)',
        () {
      expect(
        shouldAutoOpenPlayerPanel(
          contentStarting: false,
          currentKey: 'yt-1',
          suppressedKey: null,
          panelClosed: true,
        ),
        isFalse,
      );
    });

    test('does not reopen for the item the user collapsed', () {
      expect(
        shouldAutoOpenPlayerPanel(
          contentStarting: true,
          currentKey: 'yt-1',
          suppressedKey: 'yt-1',
          panelClosed: true,
        ),
        isFalse,
      );
    });

    test('a different item auto-opens again despite an old suppressed key', () {
      expect(
        shouldAutoOpenPlayerPanel(
          contentStarting: true,
          currentKey: 'yt-2',
          suppressedKey: 'yt-1',
          panelClosed: true,
        ),
        isTrue,
      );
    });

    test('does not open when the panel is already open', () {
      expect(
        shouldAutoOpenPlayerPanel(
          contentStarting: true,
          currentKey: 'yt-1',
          suppressedKey: null,
          panelClosed: false,
        ),
        isFalse,
      );
    });

    test('does not open when there is no current content key', () {
      expect(
        shouldAutoOpenPlayerPanel(
          contentStarting: true,
          currentKey: null,
          suppressedKey: null,
          panelClosed: true,
        ),
        isFalse,
      );
    });
  });
}
