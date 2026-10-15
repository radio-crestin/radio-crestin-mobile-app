import 'package:extended_image/extended_image.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/appAudioHandler.dart' show ConnectionErrorReason;
import 'package:radio_crestin/services/network_service.dart'
    show ConnectionStatus;
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/widgets/mini_player_bottom_inset.dart';
import 'package:radio_crestin/widgets/status_snackbar.dart';
import 'package:radio_crestin/widgets/status_snackbar_controller.dart';

import 'helpers/station_factory.dart';

/// The approved mockup's screen: a 390pt-wide iPhone.
const _screen = Size(390, 844);

/// The iPhone's status bar and home indicator.
const _topSafeArea = 47.0;
const _bottomSafeArea = 34.0;

/// How far the mini player sits above the screen bottom on iOS.
const _iosPanelBottomInset = 12.0;

const _offline = StatusMessage.offline(
  status: ConnectionStatus.offline,
  playIntent: true,
);
const _offlineTitleOnly =
    StatusMessage.offline(status: ConnectionStatus.offline);
const _noInternetOnMobile = StatusMessage.offline(
  status: ConnectionStatus.noInternet,
  onMobileData: true,
);
const _backOnline = StatusMessage.backOnline(resuming: true);
final _error = StatusMessage.stationError(
  stationTitle: 'Radio Vocea Evangheliei',
  reason: ConnectionErrorReason.timeout,
);

void main() {
  void useScreen(WidgetTester tester, {Size size = _screen}) {
    tester.view
      ..physicalSize = size * 3
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// Hosts [child] the way the app does: a themed page under the status
  /// bar, optionally with a screen reader running or larger text.
  Widget page(
    Widget child, {
    ThemeData? theme,
    bool accessibleNavigation = false,
    double textScale = 1,
  }) {
    return MaterialApp(
      theme: theme ?? lightTheme,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            accessibleNavigation: accessibleNavigation,
            textScaler: TextScaler.linear(textScale),
            padding: const EdgeInsets.only(
              top: _topSafeArea,
              bottom: _bottomSafeArea,
            ),
          ),
          child: Scaffold(body: child),
        ),
      ),
    );
  }

  /// The colors of every span of the rich text reading [text].
  Map<String, Color?> spanColors(WidgetTester tester, String text) {
    final rich = tester.widget<RichText>(find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == text));
    final colors = <String, Color?>{};
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text != null) {
        colors[span.text!] = span.style?.color;
      }
      return true;
    });
    return colors;
  }

  group('StatusSnackbar', () {
    late ValueNotifier<StatusMessage?> message;
    late int dismissed;
    late int retries;

    setUp(() {
      message = ValueNotifier(null);
      dismissed = 0;
      retries = 0;
    });
    tearDown(() => message.dispose());

    Future<void> pumpSnackbar(
      WidgetTester tester, {
      StatusMessage? initial,
      ThemeData? theme,
      double textScale = 1,
      bool dense = false,
      Size screen = _screen,
    }) async {
      useScreen(tester, size: screen);
      message.value = initial;
      await tester.pumpWidget(page(
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(kStatusSnackbarMargin),
            child: ValueListenableBuilder<StatusMessage?>(
              valueListenable: message,
              builder: (context, value, _) => StatusSnackbar(
                message: value,
                dense: dense,
                onDismissed: () => dismissed++,
                onRetry: () => retries++,
              ),
            ),
          ),
        ),
        theme: theme,
        textScale: textScale,
      ));
      await tester.pumpAndSettle();
    }

    Finder card() => find.byKey(StatusSnackbar.cardKey);

    Finder surface() => find.descendant(
          of: card(),
          matching: find.byWidgetPredicate((widget) =>
              widget is DecoratedBox && widget.decoration is BoxDecoration),
        );

    Color? textColor(WidgetTester tester, String text) =>
        tester.widget<Text>(find.text(text)).style?.color;

    Color? iconColor(WidgetTester tester, IconData icon) =>
        tester.widget<Icon>(find.byIcon(icon)).color;

    /// The enter/exit fade of the snackbar.
    double visibility(WidgetTester tester) => tester
        .widget<Opacity>(
            find.ancestor(of: card(), matching: find.byType(Opacity)).first)
        .opacity;

    testWidgets('shows nothing without a message', (tester) async {
      await pumpSnackbar(tester);

      expect(card(), findsNothing);
    });

    testWidgets('offline while a station plays: it resumes by itself',
        (tester) async {
      await pumpSnackbar(tester, initial: _offline);

      expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
      expect(tester.getSize(find.byIcon(Icons.wifi_off_rounded)),
          const Size(22, 22));
      expect(find.text('Nu ai conexiune la internet'), findsOneWidget);
      expect(
        find.text('Redarea pornește singură când revine internetul.'),
        findsOneWidget,
      );
      expect(find.text('Reîncearcă'), findsNothing);
    });

    testWidgets(
        'offline with nothing playing: the title alone, one '
        'centred line, 52pt tall', (tester) async {
      // The test font draws every glyph 1em wide, so a wide screen stands
      // in for the room the real font leaves at 390pt.
      await pumpSnackbar(
        tester,
        initial: _offlineTitleOnly,
        screen: const Size(800, 844),
      );

      final title = find.text('Nu ai conexiune la internet');
      expect(find.descendant(of: card(), matching: find.byType(Text)),
          findsOneWidget);
      expect(tester.getSize(card()).height, 52);
      expect(tester.getCenter(title).dy,
          closeTo(tester.getCenter(card()).dy, 0.5));
      expect(tester.getCenter(find.byIcon(Icons.wifi_off_rounded)).dy,
          closeTo(tester.getCenter(card()).dy, 0.5));
    });

    testWidgets('a network without internet says which network',
        (tester) async {
      await pumpSnackbar(
        tester,
        initial: const StatusMessage.offline(
          status: ConnectionStatus.noInternet,
          playIntent: true,
        ),
      );
      expect(
        find.text('Ești conectat la WiFi, dar rețeaua nu are internet.'),
        findsOneWidget,
      );

      message.value = _noInternetOnMobile;
      await tester.pumpAndSettle();
      expect(
        find.text('Ești conectat la date mobile, dar rețeaua nu are '
            'internet.'),
        findsOneWidget,
      );
    });

    testWidgets('back online: one line, saying playback continues',
        (tester) async {
      await pumpSnackbar(tester, initial: _backOnline);

      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(
          tester.getSize(find.byIcon(Icons.check_rounded)), const Size(20, 20));
      expect(
        find.text('Conectat din nou · redarea continuă', findRichText: true),
        findsOneWidget,
      );
      expect(tester.getSize(card()).height, 52);
    });

    testWidgets('back online without playback: no continuation',
        (tester) async {
      await pumpSnackbar(
        tester,
        initial: const StatusMessage.backOnline(resuming: false),
      );

      expect(find.text('Conectat din nou', findRichText: true), findsOneWidget);
      expect(find.textContaining('redarea', findRichText: true), findsNothing);
    });

    testWidgets('station error: artwork, one-line title, reason, retry',
        (tester) async {
      await pumpSnackbar(tester, initial: _error);

      // No station given: the neutral fallback artwork.
      expect(find.byIcon(Icons.radio_rounded), findsOneWidget);
      final title = tester.widget<Text>(find.text('Radio Vocea Evangheliei'));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(find.text('Conexiunea a expirat'), findsOneWidget);

      final retry = find.widgetWithText(TextButton, 'Reîncearcă');
      expect(retry, findsOneWidget);
      final target = tester.getSize(retry);
      expect(target.width, greaterThanOrEqualTo(48));
      expect(target.height, greaterThanOrEqualTo(48));

      await tester.tap(retry);
      expect(retries, 1);
    });

    testWidgets('station error shows the station artwork', (tester) async {
      await pumpSnackbar(
        tester,
        initial: StatusMessage.stationError(
          stationTitle: 'Radio Vocea Evangheliei',
          reason: ConnectionErrorReason.timeout,
          station: StationFactory.createStation(
            id: 1,
            slug: 'vocea-evangheliei',
            title: 'Radio Vocea Evangheliei',
          ),
        ),
      );

      final artwork = find.byType(ExtendedImage);
      expect(artwork, findsOneWidget);
      expect(tester.getSize(artwork), const Size(40, 40));
      expect(find.byIcon(Icons.radio_rounded), findsNothing);
    });

    for (final (name, theme, colors, background) in [
      ('dark', darkTheme, StatusSnackbarColors.onDark, 0xFFECE6E9),
      ('light', lightTheme, StatusSnackbarColors.onLight, 0xFF2E2A2D),
    ]) {
      Future<void> expectSurface(WidgetTester tester) async {
        final decoration =
            tester.widget<DecoratedBox>(surface()).decoration as BoxDecoration;
        expect(decoration.color, Color(background));
        expect(decoration.color, colors.background);
        expect(decoration.borderRadius, BorderRadius.circular(14));
        expect(decoration.boxShadow, const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 20,
            offset: Offset(0, 6),
          ),
        ]);
      }

      testWidgets('offline uses the inverse surface in the $name theme',
          (tester) async {
        await pumpSnackbar(tester, initial: _offline, theme: theme);

        await expectSurface(tester);
        expect(textColor(tester, 'Nu ai conexiune la internet'), colors.text);
        expect(
          textColor(
              tester,
              'Redarea pornește singură când revine '
              'internetul.'),
          colors.textSecondary,
        );
        expect(iconColor(tester, Icons.wifi_off_rounded), colors.textSecondary);
      });

      testWidgets('back online uses the inverse surface in the $name theme',
          (tester) async {
        await pumpSnackbar(tester, initial: _backOnline, theme: theme);

        await expectSurface(tester);
        expect(iconColor(tester, Icons.check_rounded), colors.success);
        expect(
          spanColors(tester, 'Conectat din nou · redarea continuă'),
          {
            'Conectat din nou': colors.text,
            ' · redarea continuă': colors.textSecondary,
          },
        );
      });

      testWidgets(
          'a station error uses the inverse surface in the $name '
          'theme', (tester) async {
        await pumpSnackbar(tester, initial: _error, theme: theme);

        await expectSurface(tester);
        expect(textColor(tester, 'Radio Vocea Evangheliei'), colors.text);
        expect(textColor(tester, 'Conexiunea a expirat'), colors.textSecondary);
        expect(iconColor(tester, Icons.radio_rounded), colors.textSecondary);
        final retryStyle = tester
            .widget<TextButton>(find.byType(TextButton))
            .style!
            .foregroundColor!
            .resolve(const {});
        expect(retryStyle, colors.action);
      });
    }

    test('theme colors match the approved palette', () {
      const dark = StatusSnackbarColors.onDark;
      const light = StatusSnackbarColors.onLight;
      expect(darkTheme.statusSnackbarColors, dark);
      expect(lightTheme.statusSnackbarColors, light);
      expect(
        [dark.text, dark.textSecondary, dark.action, dark.success],
        const [
          Color(0xFF1C1B1D),
          Color(0xFF4A4549),
          Color(0xFFA3134E),
          Color(0xFF1E7B3A),
        ],
      );
      expect(
        [light.text, light.action, light.success],
        const [Color(0xFFF4EFF2), Color(0xFFFFB0C8), Color(0xFF6FDC8C)],
      );
      expect(light.textSecondary.toARGB32() & 0xFFFFFF, 0xF4EFF2);
      expect(light.textSecondary.a, closeTo(0.74, 0.005));
    });

    testWidgets('a swipe down dismisses a station error', (tester) async {
      await pumpSnackbar(tester, initial: _error);

      await tester.drag(card(), const Offset(0, 300));
      await tester.pumpAndSettle();

      expect(dismissed, 1);
      expect(find.text('Radio Vocea Evangheliei'), findsNothing);
    });

    testWidgets('a quick flick down dismisses it too', (tester) async {
      await pumpSnackbar(tester, initial: _error);

      final height = tester.getSize(card()).height;

      // Less than the 40% that dismisses a slow swipe, but fast.
      await tester.timedDrag(
        card(),
        Offset(0, kTouchSlop + height * 0.3),
        const Duration(milliseconds: 40),
        frequency: 200,
      );
      await tester.pumpAndSettle();

      expect(dismissed, 1);
    });

    testWidgets('a short swipe down lets it back to its place',
        (tester) async {
      await pumpSnackbar(tester, initial: _error);
      final rest = tester.getRect(card());

      await tester.drag(card(), const Offset(0, 30));
      await tester.pumpAndSettle();

      expect(dismissed, 0);
      expect(tester.getRect(card()), rest);
    });

    testWidgets('over the open full player a swipe down fades it out',
        (tester) async {
      await pumpSnackbar(tester, initial: _error, dense: true);

      final finger = await tester.startGesture(tester.getCenter(card()));
      await finger.moveBy(const Offset(0, kTouchSlop + 1));
      await finger.moveBy(const Offset(0, 20));
      await tester.pump();
      expect(visibility(tester), inExclusiveRange(0, 1),
          reason: 'it fades as it follows the finger');

      await finger.moveBy(const Offset(0, 200));
      await finger.up();
      await tester.pumpAndSettle();
      expect(dismissed, 1);
    });

    testWidgets('a swipe sideways no longer dismisses it', (tester) async {
      await pumpSnackbar(tester, initial: _error);
      final rest = tester.getRect(card());

      await tester.drag(card(), const Offset(500, 0));
      await tester.pumpAndSettle();

      expect(dismissed, 0);
      expect(tester.getRect(card()), rest);
    });

    for (final (name, status) in [
      ('offline', _offline),
      ('back online', _backOnline),
    ]) {
      testWidgets('a swipe does not dismiss $name', (tester) async {
        await pumpSnackbar(tester, initial: status);
        final rest = tester.getRect(card());

        await tester.drag(card(), const Offset(0, 300));
        await tester.pumpAndSettle();

        expect(dismissed, 0);
        expect(tester.getRect(card()), rest);
      });
    }

    testWidgets('a message after a swipe shows again', (tester) async {
      await pumpSnackbar(tester, initial: _error);
      await tester.drag(card(), const Offset(0, 300));
      await tester.pumpAndSettle();

      message.value = _offline;
      await tester.pumpAndSettle();

      expect(find.text('Nu ai conexiune la internet'), findsOneWidget);
      expect(tester.getTopLeft(card()).dx, kStatusSnackbarMargin);
    });

    testWidgets('docked, it rises from under the player past its place, '
        'then settles, in 380ms', (tester) async {
      await pumpSnackbar(tester, initial: _offline);
      final rest = tester.getRect(card());
      message.value = null;
      await tester.pumpAndSettle();

      message.value = _offline;
      await tester.pump();
      expect(tester.getTopLeft(card()).dy,
          moreOrLessEquals(rest.bottom + kStatusSnackbarPlayerGap),
          reason: 'out of sight, under the mini player');
      // It starts with the next frame.
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 274));
      expect(tester.getTopLeft(card()).dy, lessThan(rest.top),
          reason: 'a little past its place');

      await tester.pump(const Duration(milliseconds: 106));
      expect(tester.getRect(card()), rest);
    });

    testWidgets('a message coming in a slow frame still rises from under '
        'the player', (tester) async {
      await pumpSnackbar(tester, initial: _offline);
      final rest = tester.getRect(card());
      message.value = null;
      await tester.pumpAndSettle();

      message.value = _offline;
      await tester.pump(); // the busy frame of the change it tells of
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getTopLeft(card()).dy,
          moreOrLessEquals(rest.bottom + kStatusSnackbarPlayerGap),
          reason: 'still under the player when its rise begins');

      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getTopLeft(card()).dy,
          inExclusiveRange(rest.top, rest.bottom + kStatusSnackbarPlayerGap));
      await tester.pumpAndSettle();
    });

    testWidgets('docked, it lifts a little, then drops under the player, '
        'in 380ms', (tester) async {
      await pumpSnackbar(tester, initial: _offline);
      final rest = tester.getRect(card());

      message.value = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 99));
      expect(tester.getTopLeft(card()).dy, lessThan(rest.top),
          reason: 'it lifts first');

      await tester.pump(const Duration(milliseconds: 280));
      expect(tester.getTopLeft(card()).dy, greaterThan(rest.top));
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.getTopLeft(card()).dy,
          moreOrLessEquals(rest.bottom + kStatusSnackbarPlayerGap));
      // Removed on the next frame.
      await tester.pump(const Duration(milliseconds: 1));
      expect(card(), findsNothing);
    });

    testWidgets('docked, what goes past the mini player\'s edge is cut off',
        (tester) async {
      await pumpSnackbar(tester, initial: _offline);

      final clip = tester.widget<ClipRect>(
          find.ancestor(of: card(), matching: find.byType(ClipRect)).first);
      final size = tester.getSize(card());

      expect(clip.clipBehavior, Clip.hardEdge);
      expect(clip.clipper!.getClip(size).bottom,
          size.height + kStatusSnackbarPlayerGap);
    });

    testWidgets('over the open full player it enters in 250ms (fast out, '
        'slow in), sliding up', (tester) async {
      await pumpSnackbar(tester, dense: true);

      message.value = _offline;
      await tester.pump();
      // It starts with the next frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      expect(visibility(tester),
          closeTo(Curves.fastOutSlowIn.transform(0.5), 0.01));
      final enteringTop = tester.getTopLeft(card()).dy;

      await tester.pump(const Duration(milliseconds: 124));
      expect(visibility(tester), lessThan(1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(visibility(tester), 1);
      expect(enteringTop, greaterThan(tester.getTopLeft(card()).dy));
    });

    testWidgets('over the open full player it exits in 200ms (ease in), '
        'sliding down', (tester) async {
      await pumpSnackbar(tester, initial: _offline, dense: true);
      final restingTop = tester.getTopLeft(card()).dy;

      message.value = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(visibility(tester), closeTo(Curves.easeIn.transform(0.5), 0.01));
      expect(tester.getTopLeft(card()).dy, greaterThan(restingTop));

      await tester.pump(const Duration(milliseconds: 99));
      expect(visibility(tester), greaterThan(0));
      await tester.pump(const Duration(milliseconds: 1));
      expect(visibility(tester), 0);
      // Removed on the next frame.
      await tester.pump(const Duration(milliseconds: 1));
      expect(card(), findsNothing);
    });

    testWidgets('cross-fades its content in 250ms when the status changes',
        (tester) async {
      await pumpSnackbar(tester, initial: _offline);

      message.value = _backOnline;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      expect(find.text('Nu ai conexiune la internet'), findsOneWidget);
      expect(
          find.text('Conectat din nou · redarea continuă', findRichText: true),
          findsOneWidget);

      double outgoing() => tester
          .widget<FadeTransition>(find
              .ancestor(
                of: find.text('Nu ai conexiune la internet'),
                matching: find.byType(FadeTransition),
              )
              .first)
          .opacity
          .value;
      await tester.pump(const Duration(milliseconds: 124));
      expect(outgoing(), greaterThan(0));
      await tester.pump(const Duration(milliseconds: 1));
      expect(outgoing(), 0);
      // Removed on the next frame.
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Nu ai conexiune la internet'), findsNothing);
    });

    testWidgets('a live region; only a station error has a dismiss action',
        (tester) async {
      Semantics region() =>
          tester.widget<Semantics>(find.byWidgetPredicate((widget) =>
              widget is Semantics &&
              widget.container &&
              widget.properties.liveRegion == true));

      await pumpSnackbar(tester, initial: _offline);
      expect(region().properties.onDismiss, isNull);

      message.value = _error;
      await tester.pumpAndSettle();
      region().properties.onDismiss!();
      expect(dismissed, 1);
    });

    testWidgets(
        'keeps the retry beside the text while it has room, and '
        'moves it under the text when it would not', (tester) async {
      // The test font draws every glyph 1em wide, so a wide screen stands
      // in for the room the real font leaves at 390pt.
      useScreen(tester, size: const Size(800, 844));
      Future<void> pumpAt(double scale) => tester.pumpWidget(page(
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(kStatusSnackbarMargin),
                child: StatusSnackbar(
                  message: _error,
                  onDismissed: () {},
                  onRetry: () {},
                ),
              ),
            ),
            textScale: scale,
          ));
      final retry = find.byType(TextButton);
      final reason = find.text('Conexiunea a expirat');

      await pumpAt(1);
      expect(tester.getTopLeft(retry).dx,
          greaterThan(tester.getTopRight(reason).dx));

      await pumpAt(3);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(retry).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(reason).dy));
      expect(tester.getTopRight(retry).dx,
          lessThanOrEqualTo(800 - kStatusSnackbarMargin));
      expect(tester.takeException(), isNull);
    });

    group('one-line form', () {
      testWidgets('offline: the title alone, its explanation still spoken',
          (tester) async {
        final semantics = tester.ensureSemantics();
        await pumpSnackbar(tester, initial: _offline, dense: true);

        expect(find.text(_offline.title), findsOneWidget);
        expect(find.text(_offline.body!), findsNothing);
        expect(
          find.bySemanticsLabel('${_offline.title}. ${_offline.body}'),
          findsOneWidget,
        );
        expect(tester.getSize(card()).height, 40);
        semantics.dispose();
      });

      testWidgets('station error: artwork, reason and retry in one line',
          (tester) async {
        // The test font draws every glyph 1em wide, so a wide screen stands
        // in for the room the real font leaves at 390pt.
        await pumpSnackbar(
          tester,
          initial: _error,
          dense: true,
          screen: const Size(800, 844),
        );

        expect(find.text('Conexiunea a expirat'), findsOneWidget);
        expect(find.text('Radio Vocea Evangheliei'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Reîncearcă'), findsOneWidget);
        // The retry's 48pt touch target sets the height.
        expect(tester.getSize(card()).height, 48);

        await tester.tap(find.widgetWithText(TextButton, 'Reîncearcă'));
        expect(retries, 1);
      });

      testWidgets('with large text the retry keeps the line as an icon',
          (tester) async {
        await pumpSnackbar(tester, initial: _error, dense: true, textScale: 3);

        expect(find.widgetWithText(TextButton, 'Reîncearcă'), findsNothing);
        final retry = find.byTooltip('Reîncearcă');
        expect(retry, findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(retry);
        expect(retries, 1);
      });

      testWidgets('back online: the same line, 40pt tall', (tester) async {
        await pumpSnackbar(tester, initial: _backOnline, dense: true);

        expect(spanColors(tester, 'Conectat din nou · redarea continuă'),
            hasLength(2));
        expect(tester.getSize(card()).height, 40);
      });

      for (final scale in [1.4, 2.0]) {
        testWidgets('every variant fits at text scale $scale',
            (tester) async {
          await pumpSnackbar(
            tester,
            initial: _error,
            textScale: scale,
            dense: true,
          );
          expect(tester.takeException(), isNull);

          for (final next in [_offline, _noInternetOnMobile, _backOnline]) {
            message.value = next;
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: next.contentKey);
          }
        });
      }
    });

    for (final scale in [1.4, 2.0]) {
      testWidgets('every variant fits at text scale $scale', (tester) async {
        await pumpSnackbar(
          tester,
          initial: StatusMessage.stationError(
            stationTitle: 'Radio Vocea Evangheliei — Cluj-Napoca și Bistrița',
            reason: ConnectionErrorReason.httpError,
          ),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);

        for (final next in [
          _offline,
          _offlineTitleOnly,
          _noInternetOnMobile,
          _backOnline,
        ]) {
          message.value = next;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: next.contentKey);
        }
      });
    }
  });

  group('statusSnackbarDockedBottom', () {
    test('8pt above the collapsed mini player', () {
      expect(
        statusSnackbarDockedBottom(
          hasMiniPlayer: true,
          bottomSafeArea: _bottomSafeArea,
          panelBottomInset: _iosPanelBottomInset,
        ),
        _iosPanelBottomInset + kMiniPlayerCollapsedHeight + 8,
      );
      expect(kMiniPlayerCollapsedHeight + 8, 104);
    });

    test('without a mini player, 12pt above the bottom safe area', () {
      // iOS: the panel's 12pt inset lies inside the 34pt home indicator
      // area.
      expect(
        statusSnackbarDockedBottom(
          hasMiniPlayer: false,
          bottomSafeArea: _bottomSafeArea,
          panelBottomInset: _iosPanelBottomInset,
        ),
        _bottomSafeArea + 12,
      );

      // An iPhone with a home button has no safe area under the inset.
      expect(
        statusSnackbarDockedBottom(
          hasMiniPlayer: false,
          bottomSafeArea: 0,
          panelBottomInset: _iosPanelBottomInset,
        ),
        _iosPanelBottomInset + 12,
      );

      // Android: the inset is the safe area.
      expect(
        statusSnackbarDockedBottom(
          hasMiniPlayer: false,
          bottomSafeArea: 24,
          panelBottomInset: 24,
        ),
        24 + 12,
      );
    });
  });

  group('statusSnackbarTop', () {
    test('docked, then raised by the panel', () {
      double top(double rise) => statusSnackbarTop(
            areaHeight: 800,
            height: 60,
            bottom: 104,
            rise: rise,
            minTop: 51,
          );

      expect(top(0), 800 - 104 - 60);
      expect(top(300), 800 - 104 - 300 - 60);
    });

    test('never above the status bar', () {
      expect(
        statusSnackbarTop(
          areaHeight: 800,
          height: 60,
          bottom: 104,
          rise: 700,
          minTop: 51,
        ),
        51,
      );
    });
  });

  group('StatusSnackbarOverlay', () {
    final withMiniPlayer = statusSnackbarDockedBottom(
      hasMiniPlayer: true,
      bottomSafeArea: _bottomSafeArea,
      panelBottomInset: _iosPanelBottomInset,
    );
    final withoutMiniPlayer = statusSnackbarDockedBottom(
      hasMiniPlayer: false,
      bottomSafeArea: _bottomSafeArea,
      panelBottomInset: _iosPanelBottomInset,
    );
    // As on the home page: the open panel is 90% of the screen; collapsed,
    // it is the mini player over the panel's bottom inset.
    final travel = _screen.height * .9 -
        _iosPanelBottomInset -
        kMiniPlayerCollapsedHeight;
    const minTop = _topSafeArea + kStatusSnackbarTopGap;

    late StatusSnackbarController controller;
    late ValueNotifier<double> panel;
    late ValueNotifier<double> listInset;
    late ValueNotifier<double> dockedBottom;
    late int retries;

    setUp(() {
      controller = StatusSnackbarController();
      panel = ValueNotifier(0);
      listInset = ValueNotifier(0);
      dockedBottom = ValueNotifier(withMiniPlayer);
      retries = 0;
    });
    tearDown(() {
      controller.dispose();
      panel.dispose();
      listInset.dispose();
      dockedBottom.dispose();
    });

    // As on the home page: the list keeps the collapsed panel's room.
    const panelMinHeight = _iosPanelBottomInset + kMiniPlayerCollapsedHeight;

    Widget overlay({double listReservedInset = panelMinHeight}) =>
        ValueListenableBuilder<double>(
          valueListenable: dockedBottom,
          builder: (context, bottom, _) => StatusSnackbarOverlay(
            controller: controller,
            panelPosition: panel,
            panelTravel: travel,
            dockedBottom: bottom,
            listInset: listInset,
            listReservedInset: listReservedInset,
            onRetry: () => retries++,
          ),
        );

    Future<void> pumpOverlay(
      WidgetTester tester, {
      bool accessibleNavigation = false,
      double listReservedInset = panelMinHeight,
    }) async {
      useScreen(tester);
      await tester.pumpWidget(page(
        Stack(
          children: [
            Positioned.fill(
              child: overlay(listReservedInset: listReservedInset),
            ),
          ],
        ),
        accessibleNavigation: accessibleNavigation,
      ));
    }

    void goOffline() =>
        controller.updateNetwork(ConnectionStatus.offline, onMobileData: false);

    void showError() => controller.showStationError(
          stationTitle: 'Radio Vocea Evangheliei',
          reason: ConnectionErrorReason.unknown,
        );

    Finder card() => find.byKey(StatusSnackbar.cardKey);

    /// The top edge of the panel, in screen coordinates.
    double panelTop(double position) =>
        _screen.height -
        _iosPanelBottomInset -
        kMiniPlayerCollapsedHeight -
        position * travel;

    testWidgets('docks 8pt above the mini player, inset from the edges',
        (tester) async {
      await pumpOverlay(tester);

      goOffline();
      await tester.pumpAndSettle();

      final rect = tester.getRect(card());
      expect(rect.bottom, panelTop(0) - 8);
      expect(rect.left, kStatusSnackbarMargin);
      expect(rect.right, _screen.width - kStatusSnackbarMargin);
    });

    testWidgets('without a mini player, docks above the bottom safe area',
        (tester) async {
      dockedBottom.value = withoutMiniPlayer;
      await pumpOverlay(tester, listReservedInset: 0);

      goOffline();
      await tester.pumpAndSettle();

      // 12pt above the home indicator area.
      expect(tester.getRect(card()).bottom, _screen.height - withoutMiniPlayer);
      expect(withoutMiniPlayer, _bottomSafeArea + 12);
    });

    testWidgets('glides to its new dock when the mini player appears',
        (tester) async {
      dockedBottom.value = withoutMiniPlayer;
      await pumpOverlay(tester);
      goOffline();
      await tester.pumpAndSettle();

      dockedBottom.value = withMiniPlayer;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      final midway = _screen.height - tester.getRect(card()).bottom;
      expect(midway, inExclusiveRange(withoutMiniPlayer, withMiniPlayer));

      await tester.pump(const Duration(milliseconds: 125));
      expect(tester.getRect(card()).bottom, _screen.height - withMiniPlayer);
    });

    testWidgets('rises together with the panel, 8pt above its top',
        (tester) async {
      await pumpOverlay(tester);
      goOffline();
      await tester.pumpAndSettle();

      for (final position in [0.25, 0.5, 0.75]) {
        panel.value = position;
        await tester.pump();

        expect(tester.getRect(card()).bottom,
            closeTo(panelTop(position) - 8, 0.001));
      }
    });

    testWidgets('stays visible and usable over the open full player',
        (tester) async {
      await pumpOverlay(tester);
      showError();
      await tester.pumpAndSettle();

      panel.value = 1;
      await tester.pumpAndSettle();

      for (final opacity in tester.widgetList<Opacity>(
          find.ancestor(of: card(), matching: find.byType(Opacity)))) {
        expect(opacity.opacity, 1);
      }
      // The one-line form: the reason, without the station's name. Its
      // retry is an icon here: the test font's glyphs are 1em wide.
      expect(find.text('Nu răspunde momentan'), findsOneWidget);
      expect(find.text('Radio Vocea Evangheliei'), findsNothing);
      await tester.tap(find.byTooltip('Reîncearcă'));
      expect(retries, 1);
    });

    testWidgets(
        'over the open full player it turns into one line under the '
        'status bar', (tester) async {
      await pumpOverlay(tester);
      // Two lines docked: the explanation that playback resumes by itself.
      controller.playIntent = true;
      goOffline();
      await tester.pumpAndSettle();
      final docked = tester.getSize(card()).height;
      // The docked form would not fit above the open panel on this screen.
      expect(panelTop(1) - 8 - docked, lessThan(minTop));

      panel.value = 1;
      await tester.pump();
      // Still docked-height at the first frame: held under the status bar.
      expect(tester.getRect(card()).top, minTop);

      await tester.pumpAndSettle();
      final rect = tester.getRect(card());
      expect(find.text(_offline.body!), findsNothing);
      expect(rect.top, minTop);
      // The open panel's top is 10% down the screen, closer to the status
      // bar than even the one-line form is tall on this phone, so it still
      // reaches onto the panel's top edge, by less than the docked form.
      expect(rect.height, lessThan(docked));
      expect(rect.bottom, greaterThan(panelTop(1)));

      // Closing the panel brings the docked form back.
      panel.value = 0;
      await tester.pumpAndSettle();
      expect(tester.getSize(card()).height, docked);
      expect(tester.getRect(card()).bottom, panelTop(0) - 8);
    });

    testWidgets('turns into one line from halfway open, and back',
        (tester) async {
      await pumpOverlay(tester);
      controller.playIntent = true;
      goOffline();
      await tester.pumpAndSettle();
      final body = find.text(_offline.body!);
      expect(body, findsOneWidget);

      panel.value = 0.49;
      await tester.pumpAndSettle();
      expect(body, findsOneWidget);

      panel.value = 0.5;
      await tester.pumpAndSettle();
      expect(body, findsNothing);

      panel.value = 0.3;
      await tester.pumpAndSettle();
      expect(body, findsOneWidget);
    });

    testWidgets("the one-line form leaves the list's room as it was",
        (tester) async {
      await pumpOverlay(tester);
      goOffline();
      await tester.pumpAndSettle();
      final room = listInset.value;
      expect(room, greaterThan(0));

      panel.value = 1;
      await tester.pumpAndSettle();
      expect(listInset.value, room);

      panel.value = 0;
      await tester.pumpAndSettle();
      expect(listInset.value, room);
    });

    testWidgets('takes no touches outside its own box', (tester) async {
      var pageTaps = 0;
      useScreen(tester);
      await tester.pumpWidget(page(
        Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => pageTaps++,
              ),
            ),
            Positioned.fill(child: overlay()),
          ],
        ),
      ));
      goOffline();
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(195, 300));
      panel.value = 1;
      await tester.pump();
      await tester.tapAt(const Offset(195, 600));

      expect(pageTaps, 2);
    });

    testWidgets('a station error leaves after exactly 6s', (tester) async {
      await pumpOverlay(tester);

      showError();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 5999));
      expect(find.text('Nu răspunde momentan'), findsOneWidget);
      expect(controller.message?.kind, StatusKind.stationError);

      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.message, isNull);
      await tester.pumpAndSettle();
      expect(find.text('Nu răspunde momentan'), findsNothing);
    });

    testWidgets('a station error stays while a screen reader runs',
        (tester) async {
      await pumpOverlay(tester, accessibleNavigation: true);

      showError();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();

      expect(find.text('Nu răspunde momentan'), findsOneWidget);
    });

    testWidgets('retry dismisses the error at once and retries',
        (tester) async {
      await pumpOverlay(tester);
      showError();
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Reîncearcă'));
      await tester.pumpAndSettle();

      expect(retries, 1);
      expect(controller.message, isNull);
      expect(find.text('Nu răspunde momentan'), findsNothing);
    });

    testWidgets('a swipe hides a station error, not the offline status',
        (tester) async {
      await pumpOverlay(tester);
      showError();
      await tester.pumpAndSettle();

      await tester.drag(card(), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(controller.message, isNull);

      goOffline();
      await tester.pumpAndSettle();
      await tester.drag(card(), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.text('Nu ai conexiune la internet'), findsOneWidget);
    });

    testWidgets(
        'the docked offline status makes room in the list: its '
        'height and the gap', (tester) async {
      await pumpOverlay(tester);

      goOffline();
      await tester.pumpAndSettle();

      final height = tester.getSize(card()).height;
      expect(listInset.value, height + 8);

      // Transient statuses make no room.
      controller.updateNetwork(ConnectionStatus.online, onMobileData: false);
      await tester.pumpAndSettle();
      expect(listInset.value, 0);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('without a mini player the list makes room down to its end',
        (tester) async {
      dockedBottom.value = withoutMiniPlayer;
      await pumpOverlay(tester, listReservedInset: 0);

      goOffline();
      await tester.pumpAndSettle();

      expect(
          listInset.value, tester.getSize(card()).height + withoutMiniPlayer);
    });

    testWidgets('never asks the list for negative room', (tester) async {
      // A station is selected (the list keeps the mini player's room) but
      // the mini player is not up yet, so the snackbar docks lower.
      dockedBottom.value = withoutMiniPlayer;
      await pumpOverlay(tester, listReservedInset: 400);

      goOffline();
      await tester.pumpAndSettle();

      expect(listInset.value, 0);
    });
  });

  group('StatusSnackbarListInset', () {
    testWidgets('animates to the room the overlay asks for', (tester) async {
      final inset = ValueNotifier(0.0);
      addTearDown(inset.dispose);
      await tester.pumpWidget(MaterialApp(
        home: CustomScrollView(
          slivers: [StatusSnackbarListInset(inset: inset)],
        ),
      ));
      Size spacer() =>
          tester.getSize(find.byType(AnimatedContainer, skipOffstage: false));
      expect(spacer().height, 0);

      inset.value = 80;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      expect(spacer().height, inExclusiveRange(0, 80));

      await tester.pumpAndSettle();
      expect(spacer().height, 80);
    });
  });
}
