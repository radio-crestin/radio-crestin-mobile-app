import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/animated_play_button.dart';
import 'package:radio_crestin/widgets/playlist_player_section.dart';

/// Layout contract of the playlist / video player body ([PlaylistPlayerLayout]):
///
///  - the prev/play/next transport sits at the SAME vertical position for every
///    item type — an audio item (below-title scrubber) and a video item (no
///    scrubber, it lives on the video overlay) must not shift it;
///  - the playlist starts COLLAPSED behind a compact header and expands /
///    collapses on tap;
///  - the labeled "Postul următor" button jumps to the next STATION, separate
///    from the transport's next-ITEM arrow.
void main() {
  const listKey = ValueKey('stub-track-list');
  const mediaKey = ValueKey('stub-media');

  /// Stand-in for the below-title seek bar: fills whatever slot it is given.
  const scrubber = SizedBox.expand(key: ValueKey('stub-scrubber'));

  Widget host({
    Widget? scrubberSlot,
    String title = 'Un titlu de element',
    String? subtitle,
    VoidCallback? onNextStation,
    int currentIndex = 2,
    int itemCount = 12,
    ValueChanged<bool>? onExpandedChanged,
  }) {
    final playButtonKey = GlobalKey<AnimatedPlayButtonState>();
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 390,
            height: 760,
            child: PlaylistPlayerLayout(
              media: const ColoredBox(key: mediaKey, color: Colors.black),
              title: title,
              subtitle: subtitle,
              scrubber: scrubberSlot,
              transport: PlaylistTransport(
                playbackStateStream: const Stream<PlaybackState>.empty(),
                playButtonKey: playButtonKey,
                repeatOne: false,
                onToggleRepeat: () {},
                onPlay: () {},
                onPause: () {},
                onStop: () {},
                onPrevious: () {},
                onNext: () {},
              ),
              onNextStation: onNextStation ?? () {},
              currentIndex: currentIndex,
              itemCount: itemCount,
              list: ListView(
                key: listKey,
                children: const [SizedBox(height: 400)],
              ),
              onExpandedChanged: onExpandedChanged,
            ),
          ),
        ),
      ),
    );
  }

  group('stable transport position', () {
    testWidgets('audio item (with scrubber) and video item (without) put the '
        'play button at the same offset', (tester) async {
      // Arrange + Act: an audio item — the below-title scrubber is shown.
      await tester.pumpWidget(host(scrubberSlot: scrubber));
      await tester.pump();
      final audioOffset = tester.getTopLeft(find.byType(AnimatedPlayButton));

      // Act: a video item — no below-title scrubber (it lives on the overlay).
      await tester.pumpWidget(host());
      await tester.pump();
      final videoOffset = tester.getTopLeft(find.byType(AnimatedPlayButton));

      // Assert.
      expect(videoOffset, audioOffset);
    });

    testWidgets('a one-line title, a two-line title and a dated item all keep '
        'the play button in place', (tester) async {
      await tester.pumpWidget(host(title: 'Scurt'));
      await tester.pump();
      final shortOffset = tester.getTopLeft(find.byType(AnimatedPlayButton));

      await tester.pumpWidget(host(
        title: 'Un titlu foarte lung care ocupă cu siguranță două rânduri '
            'întregi pe ecran și chiar mai mult',
      ));
      await tester.pump();
      expect(tester.getTopLeft(find.byType(AnimatedPlayButton)), shortOffset);

      await tester.pumpWidget(host(subtitle: '12 martie 2026'));
      await tester.pump();
      expect(tester.getTopLeft(find.byType(AnimatedPlayButton)), shortOffset);
    });

    testWidgets('expanding the playlist does not move the transport',
        (tester) async {
      await tester.pumpWidget(host());
      await tester.pump();
      final collapsedOffset = tester.getTopLeft(find.byType(AnimatedPlayButton));

      await tester.tap(find.byType(PlaylistQueueHeader));
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.byType(AnimatedPlayButton)),
          collapsedOffset);
    });
  });

  group('collapsible playlist', () {
    testWidgets('starts collapsed: only the header is shown', (tester) async {
      await tester.pumpWidget(host());
      await tester.pump();

      expect(find.byType(PlaylistQueueHeader), findsOneWidget);
      expect(find.byKey(listKey), findsNothing);
      // The header reads out the position in the list.
      expect(find.text('3 din 12'), findsOneWidget);
    });

    testWidgets('tapping the header expands the list, tapping again collapses',
        (tester) async {
      final toggles = <bool>[];
      await tester.pumpWidget(host(onExpandedChanged: toggles.add));
      await tester.pump();

      await tester.tap(find.byType(PlaylistQueueHeader));
      await tester.pumpAndSettle();
      expect(find.byKey(listKey), findsOneWidget);

      await tester.tap(find.byType(PlaylistQueueHeader));
      await tester.pumpAndSettle();
      expect(find.byKey(listKey), findsNothing);

      expect(toggles, [true, false]);
    });

    testWidgets('the expanded list is height-bounded and scrolls in place',
        (tester) async {
      await tester.pumpWidget(host());
      await tester.pump();
      await tester.tap(find.byType(PlaylistQueueHeader));
      await tester.pumpAndSettle();

      final listHeight = tester.getSize(find.byKey(listKey)).height;
      expect(listHeight, greaterThan(0));
      expect(listHeight, lessThan(760),
          reason: 'the list must fit the space left below the controls');
      // No unbounded-height / overflow exception was thrown while laying out.
      expect(tester.takeException(), isNull);
    });

    testWidgets('the chevron rotates when expanded', (tester) async {
      await tester.pumpWidget(host());
      await tester.pump();
      expect(
          tester
              .widget<AnimatedRotation>(find.byType(AnimatedRotation))
              .turns,
          0.0);

      await tester.tap(find.byType(PlaylistQueueHeader));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<AnimatedRotation>(find.byType(AnimatedRotation))
              .turns,
          0.5);
    });
  });

  group('short panels', () {
    testWidgets('a landscape-short panel shrinks the media instead of '
        'overflowing the controls', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 700,
              height: 380, // shorter than the fixed controls stack + media
              child: PlaylistPlayerLayout(
                media: const ColoredBox(key: mediaKey, color: Colors.black),
                title: 'Element',
                transport: PlaylistTransport(
                  playbackStateStream: const Stream<PlaybackState>.empty(),
                  playButtonKey: GlobalKey<AnimatedPlayButtonState>(),
                  repeatOne: false,
                  onToggleRepeat: () {},
                  onPlay: () {},
                  onPause: () {},
                  onStop: () {},
                  onPrevious: () {},
                  onNext: () {},
                ),
                onNextStation: () {},
                currentIndex: 0,
                itemCount: 3,
                list: ListView(key: listKey, children: const []),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // The transport is still fully on-screen (and therefore tappable).
      final playButton = tester.getRect(find.byType(AnimatedPlayButton));
      expect(playButton.bottom, lessThanOrEqualTo(760));
    });
  });

  group('next station button', () {
    testWidgets('tapping "Postul următor" fires the station-advance callback',
        (tester) async {
      var advances = 0;
      await tester.pumpWidget(host(onNextStation: () => advances++));
      await tester.pump();

      expect(find.text('Postul următor'), findsOneWidget);
      await tester.tap(find.byType(PlaylistNextStationButton));
      await tester.pump();

      expect(advances, 1);
    });

    testWidgets('it is NOT the transport next arrow (both exist, separately)',
        (tester) async {
      var advances = 0;
      await tester.pumpWidget(host(onNextStation: () => advances++));
      await tester.pump();

      // The round item-next arrow is still there and does not advance stations.
      expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.skip_next_rounded));
      await tester.pump();
      expect(advances, 0);
    });
  });
}
