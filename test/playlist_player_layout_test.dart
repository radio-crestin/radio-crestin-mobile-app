import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/animated_play_button.dart';
import 'package:radio_crestin/widgets/player_transport.dart';
import 'package:radio_crestin/widgets/playlist_player_section.dart';

/// Layout contract of the playlist / video player body ([PlaylistPlayerLayout]):
///
///  - order is media → title → date → "Postul următor" → queue header →
///    playlist → scrubber → transport, so the transport sits in the same
///    bottom-anchored band as the classic radio player's;
///  - the prev/play/next transport sits at the SAME vertical position for every
///    item type — an audio item (below-title scrubber) and a video item (no
///    scrubber, it lives on the video overlay) must not shift it, and neither
///    may expanding the playlist;
///  - the prev/play/next controls are the SAME SIZE as the radio full player's
///    (both render the shared [PlayerTransportControls] off the shared
///    [computePlayerLayout] metrics);
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

  group('slot order', () {
    testWidgets('"Postul următor" and the queue card sit ABOVE the transport',
        (tester) async {
      await tester.pumpWidget(host(scrubberSlot: scrubber));
      await tester.pump();

      final pillTop =
          tester.getTopLeft(find.byType(PlaylistNextStationButton)).dy;
      final queueTop = tester.getTopLeft(find.byType(PlaylistQueueHeader)).dy;
      final transportTop =
          tester.getTopLeft(find.byType(AnimatedPlayButton)).dy;
      final scrubberTop = tester.getTopLeft(find.byKey(scrubber.key!)).dy;
      // `.first` is the title slot; the queue header repeats the same text.
      final titleTop =
          tester.getTopLeft(find.text('Un titlu de element').first).dy;

      // title → pill → queue card → scrubber → transport.
      expect(titleTop, lessThan(pillTop));
      expect(pillTop, lessThan(queueTop));
      expect(queueTop, lessThan(scrubberTop));
      expect(scrubberTop, lessThan(transportTop));
    });

    testWidgets('the transport is bottom-anchored inside the section',
        (tester) async {
      await tester.pumpWidget(host());
      await tester.pump();

      final section = tester.getRect(find.byType(PlaylistPlayerLayout));
      final play = tester.getRect(find.byType(AnimatedPlayButton));
      // Only the documented bottom gap sits under the transport.
      expect(section.bottom - play.bottom, closeTo(24.0, 0.5));
    });
  });

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
      final collapsedPill =
          tester.getTopLeft(find.byType(PlaylistNextStationButton));

      await tester.tap(find.byType(PlaylistQueueHeader));
      await tester.pumpAndSettle();

      // The list took over the empty band above the scrubber; nothing else
      // moved a pixel.
      expect(find.byKey(listKey), findsOneWidget);
      expect(tester.getTopLeft(find.byType(AnimatedPlayButton)),
          collapsedOffset);
      expect(tester.getTopLeft(find.byType(PlaylistNextStationButton)),
          collapsedPill);

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

  group('transport parity with the radio full player', () {
    /// The radio full player's transport: [PlayerTransportControls] with no
    /// layout-specific extras, sized from [computePlayerLayout] — exactly what
    /// `FullAudioPlayer._buildTransportControls` renders.
    Widget radioTransport() => MaterialApp(
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => PlayerTransportControls(
                  metrics: playerLayoutOf(context),
                  playbackStateStream: const Stream<PlaybackState>.empty(),
                  playButtonKey: GlobalKey<AnimatedPlayButtonState>(),
                  onPlay: () {},
                  onPause: () {},
                  onStop: () {},
                  onPrevious: () {},
                  onNext: () {},
                ),
              ),
            ),
          ),
        );

    Widget playlistTransport({
      VoidCallback? onQuality,
      VoidCallback? onFullscreen,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PlaylistTransport(
                playbackStateStream: const Stream<PlaybackState>.empty(),
                playButtonKey: GlobalKey<AnimatedPlayButtonState>(),
                repeatOne: false,
                onToggleRepeat: () {},
                onPlay: () {},
                onPause: () {},
                onStop: () {},
                onPrevious: () {},
                onNext: () {},
                onQuality: onQuality,
                onFullscreen: onFullscreen,
              ),
            ),
          ),
        );

    Finder prev() => find.widgetWithIcon(
        PlayerSkipButton, Icons.skip_previous_rounded);
    Finder next() =>
        find.widgetWithIcon(PlayerSkipButton, Icons.skip_next_rounded);

    testWidgets('play / previous / next render at identical sizes',
        (tester) async {
      // Arrange + Act: the radio layout's cluster.
      await tester.pumpWidget(radioTransport());
      await tester.pump();
      final radioPlay = tester.getSize(find.byType(AnimatedPlayButton));
      final radioPrev = tester.getSize(prev());
      final radioNext = tester.getSize(next());

      // Act: the playlist layout's cluster, same screen.
      await tester.pumpWidget(playlistTransport());
      await tester.pump();

      // Assert: same widget, same metrics, same pixels.
      expect(tester.getSize(find.byType(AnimatedPlayButton)), radioPlay);
      expect(tester.getSize(prev()), radioPrev);
      expect(tester.getSize(next()), radioNext);
    });

    testWidgets('the gap between the trio is identical too', (tester) async {
      await tester.pumpWidget(radioTransport());
      await tester.pump();
      final radioGap = tester.getTopLeft(find.byType(AnimatedPlayButton)).dx -
          tester.getTopRight(prev()).dx;

      await tester.pumpWidget(playlistTransport());
      await tester.pump();
      final playlistGap =
          tester.getTopLeft(find.byType(AnimatedPlayButton)).dx -
              tester.getTopRight(prev()).dx;

      expect(playlistGap, closeTo(radioGap, 0.01));
    });

    testWidgets('the row height matches playerTransportRowHeight',
        (tester) async {
      await tester.pumpWidget(radioTransport());
      await tester.pump();
      final metrics = computePlayerLayout(
        screenWidth: tester.view.physicalSize.width / tester.view.devicePixelRatio,
        screenHeight:
            tester.view.physicalSize.height / tester.view.devicePixelRatio,
        textScale: 1.0,
      );
      expect(tester.getSize(find.byType(AnimatedPlayButton)).height,
          playerTransportRowHeight(metrics));
    });

    testWidgets('secondary controls never resize the trio', (tester) async {
      await tester.pumpWidget(playlistTransport());
      await tester.pump();
      final plain = tester.getSize(find.byType(AnimatedPlayButton));

      await tester.pumpWidget(playlistTransport(onQuality: () {}));
      await tester.pump();
      expect(tester.getSize(find.byType(AnimatedPlayButton)), plain);

      await tester.pumpWidget(playlistTransport(onFullscreen: () {}));
      await tester.pump();
      expect(tester.getSize(find.byType(AnimatedPlayButton)), plain);
      expect(tester.takeException(), isNull);
    });
  });
}
