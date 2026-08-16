import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/animated_play_button.dart';
import 'package:radio_crestin/widgets/player_transport.dart';
import 'package:radio_crestin/widgets/playlist_player_section.dart';

/// Layout contract of the playlist / video player body ([PlaylistPlayerLayout]):
///
///  - order is media → title (with the next-STATION control on its right) →
///    date → queue header → playlist → scrubber → transport, so the transport
///    sits in the same bottom-anchored band as the classic radio player's;
///  - the prev/play/next transport sits at the SAME vertical position for every
///    item type — an audio item (below-title scrubber) and a video item (no
///    scrubber, it lives on the video overlay) must not shift it, and neither
///    may expanding the playlist;
///  - the prev/play/next controls are the SAME SIZE as the radio full player's
///    (both render the shared [PlayerTransportControls] off the shared
///    [computePlayerLayout] metrics);
///  - the playlist opens BY DEFAULT when the elastic band can show at least two
///    rows, stays collapsed when it cannot, and the user's own toggle then wins
///    for good;
///  - the compact "Postul următor" control jumps to the next STATION, separate
///    from the transport's next-ITEM arrow.
void main() {
  const listKey = ValueKey('stub-track-list');
  const mediaKey = ValueKey('stub-media');

  /// Stand-in for the below-title seek bar: fills whatever slot it is given.
  const scrubber = SizedBox.expand(key: ValueKey('stub-scrubber'));

  /// A panel tall enough that the elastic band holds well over two rows.
  const tallPanel = 760.0;

  /// A panel whose band is under the two-row auto-expand threshold.
  const shortPanel = 600.0;

  /// Pumps [widget] on a window big enough for the hosts below.
  ///
  /// The default 800x600 test surface would CLAMP every host to 600px tall, so
  /// a "tall panel" would silently be a short one and the auto-expand decision
  /// would be measured against the wrong height.
  Future<void> pump(WidgetTester tester, Widget widget) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(widget);
  }

  Widget host({
    Widget? scrubberSlot,
    String title = 'Un titlu de element',
    String? subtitle,
    VoidCallback? onNextStation,
    int currentIndex = 2,
    int itemCount = 12,
    ValueChanged<bool>? onExpandedChanged,
    double height = tallPanel,
  }) {
    final playButtonKey = GlobalKey<AnimatedPlayButtonState>();
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 390,
            height: height,
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
    testWidgets('the queue card sits between the title and the transport',
        (tester) async {
      await pump(tester, host(scrubberSlot: scrubber));
      await tester.pump();

      final queueTop = tester.getTopLeft(find.byType(PlaylistQueueHeader)).dy;
      final transportTop =
          tester.getTopLeft(find.byType(AnimatedPlayButton)).dy;
      final scrubberTop = tester.getTopLeft(find.byKey(scrubber.key!)).dy;
      // `.first` is the title slot; the queue header repeats the same text.
      final titleTop =
          tester.getTopLeft(find.text('Un titlu de element').first).dy;

      // title → queue card → scrubber → transport.
      expect(titleTop, lessThan(queueTop));
      expect(queueTop, lessThan(scrubberTop));
      expect(scrubberTop, lessThan(transportTop));
    });

    testWidgets('the transport is bottom-anchored inside the section',
        (tester) async {
      await pump(tester, host());
      await tester.pump();

      final section = tester.getRect(find.byType(PlaylistPlayerLayout));
      final play = tester.getRect(find.byType(AnimatedPlayButton));
      // Only the documented bottom gap sits under the transport.
      expect(section.bottom - play.bottom, closeTo(24.0, 0.5));
    });
  });

  group('next-station control on the title row', () {
    testWidgets('there is no dedicated pill row — it rides on the title line',
        (tester) async {
      await pump(tester, host());
      await tester.pump();

      final control = tester.getRect(find.byType(PlaylistNextStationButton));
      final titleSlot = tester.getRect(find.text('Un titlu de element').first);

      // Vertically on the title line, horizontally at its right edge.
      expect(control.center.dy, closeTo(titleSlot.center.dy, 12.0));
      expect(control.left, greaterThanOrEqualTo(titleSlot.right));
      // The old label-and-border pill is gone.
      expect(find.text('Postul următor'), findsNothing);
    });

    testWidgets('it keeps a 44x44 tap target and still advances the station',
        (tester) async {
      var advances = 0;
      await pump(tester, host(onNextStation: () => advances++));
      await tester.pump();

      expect(tester.getSize(find.byType(PlaylistNextStationButton)),
          const Size(44, 44));
      await tester.tap(find.byType(PlaylistNextStationButton));
      await tester.pump();
      expect(advances, 1);
    });

    testWidgets('the title stays centered in the row', (tester) async {
      await pump(tester, host(title: 'Scurt'));
      await tester.pump();

      final section = tester.getRect(find.byType(PlaylistPlayerLayout));
      final title = tester.getRect(find.text('Scurt').first);
      // The ghost square on the left balances the control on the right.
      expect(title.center.dx, closeTo(section.center.dx, 1.0));
    });
  });

  group('stable transport position', () {
    testWidgets('audio item (with scrubber) and video item (without) put the '
        'play button at the same offset', (tester) async {
      // Arrange + Act: an audio item — the below-title scrubber is shown.
      await pump(tester, host(scrubberSlot: scrubber));
      await tester.pump();
      final audioOffset = tester.getTopLeft(find.byType(AnimatedPlayButton));

      // Act: a video item — no below-title scrubber (it lives on the overlay).
      await pump(tester, host());
      await tester.pump();
      final videoOffset = tester.getTopLeft(find.byType(AnimatedPlayButton));

      // Assert.
      expect(videoOffset, audioOffset);
    });

    testWidgets('a one-line title, a two-line title and a dated item all keep '
        'the play button in place', (tester) async {
      await pump(tester, host(title: 'Scurt'));
      await tester.pump();
      final shortOffset = tester.getTopLeft(find.byType(AnimatedPlayButton));

      await pump(tester, host(
        title: 'Un titlu foarte lung care ocupă cu siguranță două rânduri '
            'întregi pe ecran și chiar mai mult',
      ));
      await tester.pump();
      expect(tester.getTopLeft(find.byType(AnimatedPlayButton)), shortOffset);

      await pump(tester, host(subtitle: '12 martie 2026'));
      await tester.pump();
      expect(tester.getTopLeft(find.byType(AnimatedPlayButton)), shortOffset);
    });

    testWidgets('collapsing and re-expanding the playlist never moves the '
        'transport', (tester) async {
      // Arrange: a tall panel — the list is open by default.
      await pump(tester, host());
      await tester.pumpAndSettle();
      expect(find.byKey(listKey), findsOneWidget);
      final expandedOffset = tester.getTopLeft(find.byType(AnimatedPlayButton));
      final expandedControl =
          tester.getTopLeft(find.byType(PlaylistNextStationButton));

      // Act: collapse.
      await tester.tap(find.byType(PlaylistQueueHeader));
      await tester.pumpAndSettle();

      // Assert: the band emptied out; nothing else moved a pixel.
      expect(find.byKey(listKey), findsNothing);
      expect(
          tester.getTopLeft(find.byType(AnimatedPlayButton)), expandedOffset);
      expect(tester.getTopLeft(find.byType(PlaylistNextStationButton)),
          expandedControl);

      // Act + assert: re-expand.
      await tester.tap(find.byType(PlaylistQueueHeader));
      await tester.pumpAndSettle();
      expect(
          tester.getTopLeft(find.byType(AnimatedPlayButton)), expandedOffset);
    });

    testWidgets('a short panel puts the transport in the same place as a tall '
        'one measured from the bottom', (tester) async {
      await pump(tester, host(height: shortPanel));
      await tester.pumpAndSettle();
      final short = tester.getRect(find.byType(PlaylistPlayerLayout)).bottom -
          tester.getRect(find.byType(AnimatedPlayButton)).bottom;

      await pump(tester, host(height: tallPanel));
      await tester.pumpAndSettle();
      final tall = tester.getRect(find.byType(PlaylistPlayerLayout)).bottom -
          tester.getRect(find.byType(AnimatedPlayButton)).bottom;

      expect(short, closeTo(tall, 0.5));
    });
  });

  group('playlist opens by default when there is room', () {
    testWidgets('a tall panel starts EXPANDED', (tester) async {
      // Arrange + Act: the elastic band holds well over two rows.
      await pump(tester, host());
      await tester.pumpAndSettle();

      // Assert: no empty band — the list is showing, chevron flipped.
      expect(find.byKey(listKey), findsOneWidget);
      expect(
          tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
          0.5);
    });

    testWidgets('a short panel starts COLLAPSED', (tester) async {
      // Arrange + Act: the band is under the two-row threshold.
      await pump(tester, host(height: shortPanel));
      await tester.pumpAndSettle();

      // Assert: only the header, which still reads out the position.
      expect(find.byType(PlaylistQueueHeader), findsOneWidget);
      expect(find.byKey(listKey), findsNothing);
      expect(find.text('3 din 12'), findsOneWidget);
      expect(
          tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
          0.0);
    });

    testWidgets('a manual collapse on a tall panel STICKS across rebuilds',
        (tester) async {
      // Arrange: opened automatically, then closed by the user.
      await pump(tester, host());
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PlaylistQueueHeader));
      await tester.pumpAndSettle();
      expect(find.byKey(listKey), findsNothing);

      // Act: an unrelated rebuild (a new item's title arrives).
      await pump(tester, host(title: 'Alt element'));
      await tester.pumpAndSettle();

      // Assert: the auto rule does NOT re-open it.
      expect(find.byKey(listKey), findsNothing);
    });

    testWidgets('the automatic decision is reported once, and every toggle '
        'after it', (tester) async {
      final toggles = <bool>[];
      await pump(tester, host(onExpandedChanged: toggles.add));
      await tester.pumpAndSettle();
      expect(toggles, [true], reason: 'the auto-expand drives scroll-to-item');

      await tester.tap(find.byType(PlaylistQueueHeader));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PlaylistQueueHeader));
      await tester.pumpAndSettle();

      expect(toggles, [true, false, true]);
    });

    testWidgets('initiallyExpanded still pins the state explicitly',
        (tester) async {
      await pump(tester, MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              height: tallPanel,
              child: PlaylistPlayerLayout(
                initiallyExpanded: false,
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
      await tester.pumpAndSettle();

      expect(find.byKey(listKey), findsNothing);
    });

    testWidgets('the expanded list is height-bounded and scrolls in place',
        (tester) async {
      await pump(tester, host());
      await tester.pumpAndSettle();

      final listHeight = tester.getSize(find.byKey(listKey)).height;
      expect(listHeight, greaterThanOrEqualTo(kPlaylistAutoExpandMinBandHeight));
      expect(listHeight, lessThan(tallPanel),
          reason: 'the list must fit the space left below the controls');
      // No unbounded-height / overflow exception was thrown while laying out.
      expect(tester.takeException(), isNull);
    });
  });

  group('short panels', () {
    testWidgets('a landscape-short panel shrinks the media instead of '
        'overflowing the controls', (tester) async {
      await pump(tester, MaterialApp(
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
    testWidgets('it is NOT the transport next arrow (both exist, separately)',
        (tester) async {
      var advances = 0;
      await pump(tester, host(onNextStation: () => advances++));
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
      await pump(tester, radioTransport());
      await tester.pump();
      final radioPlay = tester.getSize(find.byType(AnimatedPlayButton));
      final radioPrev = tester.getSize(prev());
      final radioNext = tester.getSize(next());

      // Act: the playlist layout's cluster, same screen.
      await pump(tester, playlistTransport());
      await tester.pump();

      // Assert: same widget, same metrics, same pixels.
      expect(tester.getSize(find.byType(AnimatedPlayButton)), radioPlay);
      expect(tester.getSize(prev()), radioPrev);
      expect(tester.getSize(next()), radioNext);
    });

    testWidgets('the gap between the trio is identical too', (tester) async {
      await pump(tester, radioTransport());
      await tester.pump();
      final radioGap = tester.getTopLeft(find.byType(AnimatedPlayButton)).dx -
          tester.getTopRight(prev()).dx;

      await pump(tester, playlistTransport());
      await tester.pump();
      final playlistGap =
          tester.getTopLeft(find.byType(AnimatedPlayButton)).dx -
              tester.getTopRight(prev()).dx;

      expect(playlistGap, closeTo(radioGap, 0.01));
    });

    testWidgets('the row height matches playerTransportRowHeight',
        (tester) async {
      await pump(tester, radioTransport());
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
      await pump(tester, playlistTransport());
      await tester.pump();
      final plain = tester.getSize(find.byType(AnimatedPlayButton));

      await pump(tester, playlistTransport(onQuality: () {}));
      await tester.pump();
      expect(tester.getSize(find.byType(AnimatedPlayButton)), plain);

      await pump(tester, playlistTransport(onFullscreen: () {}));
      await tester.pump();
      expect(tester.getSize(find.byType(AnimatedPlayButton)), plain);
      expect(tester.takeException(), isNull);
    });
  });
}
