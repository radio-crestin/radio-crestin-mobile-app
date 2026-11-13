import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:radio_crestin/appAudioHandler.dart';

import 'package:get_it/get_it.dart';
import 'package:radio_crestin/components/StationsList.dart';
import 'package:radio_crestin/services/announcement.dart';
import 'package:radio_crestin/services/announcements_service.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/widgets/announcement_banner.dart';
import 'package:radio_crestin/widgets/announcement_card.dart';
import 'package:radio_crestin/widgets/announcement_icons.dart';
import 'package:radio_crestin/widgets/announcement_theme_colors.dart';
import 'package:radio_crestin/widgets/inline_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import 'harness/announcement_fixtures.dart';
import 'harness/fake_radio_server.dart';
import 'harness/network_conditions.dart';
import 'harness/recording_launcher.dart';
import 'harness/radio_app.dart';
import 'harness/station_catalog.dart';

/// The app's core flows, end to end, on good and bad networks. How the
/// harness works and how to add a test: README.md next to this file.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FakeRadioServer server;
  setUpAll(() async {
    server = await FakeRadioServer.start();
    // The first test launches the app, on an API this slow.
    server.conditions.set(
      const Link(latency: Duration(seconds: 3)),
      origins: [Origin.api],
    );
  });
  tearDownAll(() => server.close());

  void test(
    String description,
    Future<void> Function(RadioApp app) body, {
    bool skip = false,
  }) =>
      e2eTest(description, body, server: () => server, skip: skip);

  group('Start', () {
    test('shows every station, even when the API answers slowly',
        (app) async {
      for (final station in Stations.all) {
        final row = await app.showStation(station);
        expect(row, findsOneWidget, reason: app.describe());
      }
      await app.expectSilent();
    });
  });

  group('Playback', () {
    test('tapping a station plays it', (app) async {
      final tappedAt = await app.tapStation(Stations.alpha);
      await app.expectPlaying(Stations.alpha, since: tappedAt);
    });

    test('pause silences the station and play resumes it', (app) async {
      await app.expectPlaying(Stations.alpha,
          since: await app.tapStation(Stations.alpha));

      await app.tapMiniPlayerButton();
      await app.expectSilent();

      final resumedAt = DateTime.now();
      await app.tapMiniPlayerButton();
      await app.expectPlaying(Stations.alpha, since: resumedAt);
    });

    test('tapping another station switches the audio to it', (app) async {
      await app.expectPlaying(Stations.alpha,
          since: await app.tapStation(Stations.alpha));

      final switchedAt = await app.tapStation(Stations.beta);
      await app.expectPlaying(Stations.beta, since: switchedAt);
      await app.pumpFor(const Duration(seconds: 2));
      final settledAt = DateTime.now();
      await app.pumpFor(const Duration(seconds: 6));
      expect(server.mediaBytesSent(Stations.alpha, since: settledAt), 0,
          reason: 'the previous station stopped streaming');
    });

    test('"Folosește MP3 cu prioritate" moves the station to MP3 and back',
        (app) async {
      await app.expectPlaying(Stations.alpha,
          since: await app.tapStation(Stations.alpha));
      await app.openSettings();
      await app.toggleSetting('Mod dezvoltator');

      final mp3At = await app.toggleSetting('Folosește MP3 cu prioritate');
      await app.expectPlayingFrom(Stations.alpha, Origin.mp3, since: mp3At);

      final hlsAt = await app.toggleSetting('Folosește MP3 cu prioritate');
      await app.expectPlayingFrom(Stations.alpha, Origin.hls, since: hlsAt);
    });

    test('a station with only an MP3 stream plays it', (app) async {
      final tappedAt = await app.tapStation(Stations.gamma);
      await app.expectPlaying(Stations.gamma, since: tappedAt);
    });

    test('next and previous in the full player switch stations',
        (app) async {
      await app.expectPlaying(Stations.alpha,
          since: await app.tapStation(Stations.alpha));
      await app.openFullPlayer();

      final nextAt = await app.tapTooltip('Stația următoare');
      await app.waitFor(() => app.currentStation != Stations.alpha,
          reason: 'next to change the station');
      await app.expectPlaying(app.currentStation, since: nextAt);

      await app.expectPlaying(Stations.alpha,
          since: await app.tapTooltip('Stația anterioară'));
    });
  });

  group('Bad network', () {
    test('starts and keeps playing on a slow mobile network', (app) async {
      server.conditions.set(
        const Link(latency: Duration(milliseconds: 600), bytesPerSecond: 16000),
      );
      final tappedAt = await app.tapStation(Stations.alpha);
      await app.expectPlaying(Stations.alpha,
          since: tappedAt,
          within: const Duration(seconds: 30),
          listenFor: const Duration(seconds: 20));
    });

    test('keeps playing through a 20-second stall of the stream',
        (app) async {
      await app.expectPlaying(Stations.alpha,
          since: await app.tapStation(Stations.alpha));

      server.conditions.set(
        const Link(outage: Outage.silent),
        origins: [Origin.hls],
      );
      await app.expectAudioAdvances(const Duration(seconds: 20));
      server.conditions.restore();
      await app.expectAudioAdvances(const Duration(seconds: 10));
    });

    test('falls back to the MP3 stream when HLS is down', (app) async {
      server.conditions.set(
        const Link(outage: Outage.serverError),
        origins: [Origin.hls],
      );
      final tappedAt = await app.tapStation(Stations.alpha);
      await app.expectPlaying(Stations.alpha, since: tappedAt);
      expect(
        server.requests.any((r) =>
            r.origin == Origin.mp3 &&
            r.station == Stations.alpha.slug &&
            r.bytesSent > 0),
        isTrue,
        reason: 'the audio came from the MP3 stream',
      );
    });

    test('a station with only an MP3 stream plays when it is slow to start',
        (app) async {
      // On iPhone, AVPlayer opens an MP3 stream in two or three requests,
      // one after the other: its load takes 8-12 s, longer than the 5 s a
      // load may take when another stream could take over (a 320 kb/s
      // stream on mobile data).
      server.conditions.set(
        const Link(latency: Duration(seconds: 4)),
        origins: [Origin.mp3],
      );
      final errors = <ConnectionError>[];
      final errorsShown = app.audio.connectionError.listen(errors.add);
      addTearDown(errorsShown.cancel);

      final tappedAt = await app.tapStation(Stations.gamma);
      await app.expectPlaying(Stations.gamma,
          since: tappedAt, within: const Duration(seconds: 30));
      expect(errors, isEmpty,
          reason: 'no connection error while the station was loading');
    });

    test('reconnects by itself after the connection drops', (app) async {
      await app.expectPlaying(Stations.gamma,
          since: await app.tapStation(Stations.gamma));

      server.conditions.set(
        const Link(outage: Outage.refused),
        origins: [Origin.mp3],
      );
      await app.pumpFor(const Duration(seconds: 8));
      final restoredAt = DateTime.now();
      server.conditions.restore();
      await app.expectPlaying(Stations.gamma,
          since: restoredAt, within: const Duration(seconds: 45));
    });

    test('resumes by itself when the internet comes back', (app) async {
      await app.expectPlaying(Stations.gamma,
          since: await app.tapStation(Stations.gamma));

      server.conditions.goOffline();
      await app.waitFor(() => app.network.isOffline.value,
          reason: 'the app to notice it is offline',
          timeout: const Duration(seconds: 30));
      final restoredAt = DateTime.now();
      server.conditions.restore();
      await app.expectPlaying(Stations.gamma,
          since: restoredAt, within: const Duration(seconds: 60));
    });

    test('a station tapped while offline plays once the internet is back',
        (app) async {
      server.conditions.goOffline();
      await app.tapStation(Stations.beta);
      await app.pumpFor(const Duration(seconds: 8));
      final restoredAt = DateTime.now();
      server.conditions.restore();
      await app.expectPlaying(Stations.beta,
          since: restoredAt, within: const Duration(seconds: 60));
    });

    test('keeps playing while the API is down', (app) async {
      await app.expectPlaying(Stations.alpha,
          since: await app.tapStation(Stations.alpha));

      server.conditions.set(
        const Link(outage: Outage.serverError),
        origins: [Origin.api, Origin.images],
      );
      await app.expectAudioAdvances(const Duration(seconds: 30));
    });
  });

  group('Announcements', () {
    /// Runs [body] from a device that never saw an announcement, and
    /// leaves none behind for the tests after it.
    void announcementTest(
      String description,
      Future<void> Function(RadioApp app) body,
    ) =>
        test(description, (app) async {
          await _forgetAnnouncements(app);
          try {
            await body(app);
          } finally {
            server.announcements.clear();
            await _forgetAnnouncements(app);
          }
        });

    /// Serves the two home fixtures and pulls Home to refresh, which shows
    /// new announcements at once.
    Future<void> showAnnouncements(RadioApp app) async {
      server.announcements
        ..add(AnnouncementFixtures.verse())
        ..add(AnnouncementFixtures.concert());
      await app.pullToRefresh();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.verseTitle),
          reason: 'the announcement card to show');
    }

    announcementTest(
        'a first launch has the card in its first home frame, with the '
        'stations', (app) async {
      // A healthy API, even when this test is the run's first, slow one.
      server.conditions.restore();
      server.announcements.add(AnnouncementFixtures.verse());
      // No list kept on the device: the launch asks the API.
      await app.coldStartAnnouncements();
      expect(app.cardInFirstHomeFrame, isTrue,
          reason: 'the card is there from the first frame; ${app.describe()}');
      expect(app.showsText(AnnouncementFixtures.verseTitle), isTrue);
    });

    announcementTest('a cold start has the kept card in its first home frame',
        (app) async {
      server.announcements.add(AnnouncementFixtures.verse());
      await app.coldStartAnnouncements();
      // The API is down at the next launch: the card can only come from
      // the list the device kept.
      server.conditions.set(
        const Link(outage: Outage.serverError),
        origins: [Origin.api],
      );
      await app.coldStartAnnouncements();
      expect(app.cardInFirstHomeFrame, isTrue,
          reason: 'the kept list shows in the first frame; ${app.describe()}');
      expect(app.showsText(AnnouncementFixtures.verseTitle), isTrue);
    });

    announcementTest(
        'a list slower than the stations still shows in the same launch',
        (app) async {
      server
        ..announcements.add(AnnouncementFixtures.verse())
        ..announcementListDelay = const Duration(seconds: 3);
      await app.coldStartAnnouncements();
      expect(app.cardInFirstHomeFrame, isFalse,
          reason: 'the stations did not wait for a slow list');
      await app.waitFor(() => app.showsText(AnnouncementFixtures.verseTitle),
          reason: 'the card to grow in when the list arrives');
    });

    announcementTest(
        'a pull-to-refresh during a slow fetch gets the list as it is after '
        'the pull', (app) async {
      // A healthy API, even when this test is the run's first, slow one.
      server.conditions.restore();
      server.announcementListDelay = const Duration(seconds: 12);
      // Its fetch is still on the way: the launch waited 1.5 s, the list
      // it asked for is empty.
      await app.coldStartAnnouncements();
      server
        ..announcements.add(AnnouncementFixtures.verse())
        ..announcementListDelay = Duration.zero;
      await app.pullToRefresh();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.verseTitle),
          reason: 'the list as it is after the pull');
    });

    announcementTest(
        'a refresh keeps the announcement on screen where it is', (app) async {
      await showAnnouncements(app);
      await app.swipeAnnouncement();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.concertTitle),
          reason: 'the second announcement');
      server.announcements.insert(0, AnnouncementFixtures.newest());
      await app.pullToRefresh();
      await app.waitFor(() => app.showsText('3 din 3'),
          reason: 'the new announcement counted; ${app.describe()}');
      expect(app.showsText(AnnouncementFixtures.concertTitle), isTrue,
          reason: 'the card still shows the announcement it showed');
    });

    announcementTest(
        'max_per_load counts only the announcements meant for this phone',
        (app) async {
      server.announcementSettings = const {
        'rotation_mode': 'fixed',
        'max_per_load': 1,
      };
      server.announcements
        ..add(AnnouncementFixtures.webOnly())
        ..add(AnnouncementFixtures.verse())
        ..add(AnnouncementFixtures.concert());
      await app.pullToRefresh();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.verseTitle),
          reason: 'the first announcement meant for a phone');
      expect(app.showsText(AnnouncementFixtures.webOnlyTitle), isFalse,
          reason: 'a website-only announcement never shows in the app');
      expect(app.showsText('1 din 2'), isFalse,
          reason: 'one announcement at most, so no count and no dots');
    });

    announcementTest(
        'one line: the main button and "Ascunde"; an old second button is '
        'ignored',
        (app) async {
      server.announcements.add(AnnouncementFixtures.longButtons());
      await app.pullToRefresh();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.longPrimary),
          reason: 'the card with long buttons');
      final tester = app.tester;
      double middleOf(Finder finder) =>
          tester.getCenter(finder.hitTestable().first).dy;
      final primary = middleOf(find.text(AnnouncementFixtures.longPrimary));
      final dismiss =
          middleOf(find.byKey(const ValueKey('announcement-dismiss')));
      expect((dismiss - primary).abs(), lessThan(2),
          reason: '"Ascunde" sits on the main button\'s line');
      expect(app.showsText(AnnouncementFixtures.legacySecondary), isFalse,
          reason: 'a second button from an older list is not drawn');
    });

    announcementTest(
        'the button is the one accent: its color is the admin\'s or the '
        'app\'s, and the tag stays quiet', (app) async {
      server.announcements
        ..add(AnnouncementFixtures.verse())
        ..add(AnnouncementFixtures.uncolored());
      await app.pullToRefresh();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.verseTitle),
          reason: 'the card');
      Color fillOf(String text, Type type) {
        final box = find
            .ancestor(
                of: find.text(text).hitTestable(),
                matching: find.byType(type))
            .first;
        final widget = app.tester.widget(box);
        return switch (widget) {
          Material(:final color?) => color,
          Container(decoration: BoxDecoration(:final color?)) => color,
          _ => throw StateError('no fill on $text'),
        };
      }

      expect(fillOf('Join the group', Material), const Color(0xFF0F6E63),
          reason: "the admin's button color stays");
      final tag = fillOf('Community', Container);
      expect(tag.withValues(alpha: 1), const Color(0xFF0F6E63),
          reason: "the tag is tinted with the admin's category color");
      expect(tag.a, lessThan(0.3), reason: 'only a faint tint of it');

      await app.tapKey('announcement-next');
      await app.waitFor(
          () => app.showsText(AnnouncementFixtures.uncoloredTitle),
          reason: 'the card without colors');
      expect(fillOf(AnnouncementFixtures.uncoloredButton, Material),
          AppColors.announcementButton,
          reason: "the button takes the app's pink");
      final neutral = Theme.of(app.tester
              .element(find.text(AnnouncementFixtures.uncoloredTitle).first))
          .announcementColors
          .control;
      expect(fillOf(AnnouncementFixtures.uncoloredCategory, Container),
          neutral,
          reason: 'a tag without a color is neutral');
    });

    announcementTest(
        'a push while the app is open slides down a card as tall as its '
        'content', (app) async {
      // What a push in the foreground does once it has the announcement
      // (FCM can't reach the simulator).
      AnnouncementBanner.show(
        Announcement.fromJson(AnnouncementFixtures.concert())!,
        GetIt.instance<AnnouncementsService>(),
      );
      final card = find.byKey(const ValueKey(
          'announcement-static-${AnnouncementFixtures.concertSlug}'));
      await app.waitFor(() => card.hitTestable().evaluate().isNotEmpty,
          reason: 'the banner to slide down');
      final height = app.tester.getSize(card).height;
      expect(height, lessThan(260),
          reason: 'the banner is as tall as its card, not the screen');
      await app.tapDismiss();
      await app.waitFor(() => card.evaluate().isEmpty,
          reason: 'the banner to go after "Ascunde"');
    });

    announcementTest(
        'a title-only announcement leaves no gap for its empty body in the '
        'card, the push banner and the page', (app) async {
      server.announcements.add(AnnouncementFixtures.titleOnly());
      await app.pullToRefresh();
      await app.waitFor(
          () => app.showsText(AnnouncementFixtures.titleOnlyTitle),
          reason: 'the card');
      final card = RadioApp.announcementCard;
      expect(
          find.descendant(of: card, matching: find.byType(InlineMarkdownText)),
          findsNothing,
          reason: 'no body line');
      // The card also lays out an invisible copy of the slide; the last
      // one is the slide on screen.
      final titleBottom = app.tester
          .getBottomLeft(find.text(AnnouncementFixtures.titleOnlyTitle).last)
          .dy;
      final buttonTop = app.tester
          .getTopLeft(find.text(AnnouncementFixtures.titleOnlyButton).last)
          .dy;
      expect(buttonTop - titleBottom, lessThan(36),
          reason: 'the button sits right under the title');

      // The push banner shows the same slide.
      AnnouncementBanner.show(
        Announcement.fromJson(AnnouncementFixtures.titleOnly())!,
        GetIt.instance<AnnouncementsService>(),
      );
      final banner = find.byKey(const ValueKey(
          'announcement-static-${AnnouncementFixtures.titleOnlySlug}'));
      await app.waitFor(() => banner.hitTestable().evaluate().isNotEmpty,
          reason: 'the banner to slide down');
      expect(
          find.descendant(
              of: banner, matching: find.byType(InlineMarkdownText)),
          findsNothing,
          reason: 'no body line in the banner');
      AnnouncementBanner.hide();
      await app.pumpFor(const Duration(milliseconds: 500));

      await app.tapText(AnnouncementFixtures.titleOnlyButton);
      await app.waitFor(
          () => find.byKey(const ValueKey('markdown')).evaluate().isNotEmpty,
          reason: 'the page, loaded');
      expect(find.byType(MarkdownBody), findsNothing,
          reason: 'the page has no empty text block');
    });

    announcementTest(
        'a long button label wraps in its button and "Ascunde" stays in the '
        'card, on a small phone with large text', (app) async {
      final item = Announcement.fromJson(AnnouncementFixtures.whatsappVerse())!;
      final service = GetIt.instance<AnnouncementsService>();
      const sizes = [(320.0, 1.3), (375.0, 1.3), (375.0, 1.0)];
      Key frameKey(double width, double scale) => ValueKey('fit-$width-$scale');
      await app.tester.pumpWidget(MaterialApp(
        theme: darkTheme,
        home: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              child: Column(children: [
                for (final (width, scale) in sizes)
                  Builder(
                    builder: (context) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: Container(
                        key: frameKey(width, scale),
                        width: width,
                        padding: const EdgeInsets.symmetric(
                            horizontal: StationsList.cardSideInset,
                            vertical: 8),
                        child:
                            AnnouncementStaticCard(item: item, service: service),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ));
      await app.pumpFor(const Duration(seconds: 1));

      final tester = app.tester;
      for (final (width, scale) in sizes) {
        final frame = find.byKey(frameKey(width, scale));
        Finder inFrame(Finder finder) =>
            find.descendant(of: frame, matching: finder);
        final card = tester.getRect(frame).deflate(StationsList.cardSideInset);
        final dismiss =
            tester.getRect(inFrame(find.byKey(const ValueKey(
                'announcement-dismiss'))));
        final label = inFrame(find.text(AnnouncementFixtures.whatsappButton));
        final where = '${width.toInt()} px at text ${scale}x';
        expect(dismiss.right, lessThanOrEqualTo(card.right),
            reason: '"Ascunde" inside the card, $where');
        expect(card.right - dismiss.right, lessThan(24),
            reason: '"Ascunde" on the right, $where');
        expect(tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
            isFalse,
            reason: 'the whole label shows, $where');
        // Beside the button, or under it when two lines are not enough.
        final button = tester.getRect(find
            .ancestor(of: label, matching: find.byType(InkWell))
            .first);
        expect(
            button.right <= dismiss.left || button.bottom <= dismiss.top,
            isTrue,
            reason: 'the button and "Ascunde" do not overlap, $where');
      }
      expect(tester.takeException(), isNull, reason: 'no overflow');
    });

    announcementTest(
        "the icon tile and the tag take the announcement's hue, readable at "
        'AA in both themes', (app) async {
      // Hue: the button's color, else the category's, else none.
      final themes = {'light': lightTheme, 'dark': darkTheme};
      for (final MapEntry(key: name, value: theme) in themes.entries) {
        for (final hex in ['#0D8040', '#075E54', '#0F6E63', '#F5C518']) {
          for (final onButton in [true, false]) {
            final item = Announcement.fromJson(
                AnnouncementFixtures.hued(hex, onButton: onButton))!;
            final where = '$hex on the ${onButton ? 'button' : 'category'}, '
                '$name theme';
            expect(theme.announcementHue(item), parseHexColor(hex),
                reason: 'the hue, $where');
            for (final surface in [
              theme.announcementCardSurface,
              theme.scaffoldBackgroundColor,
            ]) {
              final fill = Color.alphaBlend(
                  theme.announcementTagColor(item), surface);
              expect(
                  contrastRatio(
                      theme.announcementTagLabel(item, surface: surface),
                      fill),
                  greaterThanOrEqualTo(minTextContrast),
                  reason: 'the tag reads at AA, $where');
            }
          }
        }
        final plain =
            Announcement.fromJson(AnnouncementFixtures.hued(null))!;
        expect(theme.announcementHue(plain), isNull);
        expect(theme.announcementIconTileColor(plain),
            theme.announcementColors.control,
            reason: 'no hue: the tile stays neutral, $name theme');
        expect(theme.announcementTagLabel(plain),
            theme.announcementColors.muted);
      }

      // The live WhatsApp card, in both themes at 390 px.
      final item = Announcement.fromJson(AnnouncementFixtures.whatsappLive())!;
      final service = GetIt.instance<AnnouncementsService>();
      await app.tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Column(children: [
              for (final MapEntry(key: name, value: theme) in themes.entries)
                Theme(
                  data: theme,
                  child: Container(
                    key: ValueKey('hue-$name'),
                    width: 390,
                    color: theme.scaffoldBackgroundColor,
                    padding: const EdgeInsets.all(StationsList.cardSideInset),
                    child: AnnouncementStaticCard(item: item, service: service),
                  ),
                ),
            ]),
          ),
        ),
      ));
      await app.pumpFor(const Duration(seconds: 1));
      for (final MapEntry(key: name, value: theme) in themes.entries) {
        final frame = find.byKey(ValueKey('hue-$name'));
        Finder inFrame(Finder finder) =>
            find.descendant(of: frame, matching: finder);
        final glyph = app.tester.widget<Icon>(inFrame(find.descendant(
            of: find.byKey(const ValueKey('announcement-icon-tile')),
            matching: find.byType(Icon))));
        expect(glyph.color, theme.announcementGlyphColor(item),
            reason: 'the glyph in the hue, $name theme');
        final label =
            app.tester.widget<Text>(inFrame(find.text(AnnouncementFixtures.whatsappJoin)));
        expect(label.style?.color, const Color(0xFFFFFFFF),
            reason: 'the admin\'s white button text, $name theme');
        expect(
            inFrame(find.byIcon(announcementIcons['whatsapp']!)),
            findsNWidgets(2),
            reason: 'the WhatsApp icon on the tile and the button, $name');
      }
    });

    announcementTest(
        "a page's YouTube links are thumbnails that open YouTube, pausing "
        'the radio', (app) async {
      server.announcements.add(AnnouncementFixtures.videos());
      await app.expectPlaying(Stations.alpha,
          since: await app.tapStation(Stations.alpha));
      await app.pullToRefresh();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.videoTitle),
          reason: 'the card');
      await app.tapText(AnnouncementFixtures.videoTitle);
      await app.waitFor(
          () => app.showsText(AnnouncementFixtures.videoPageTitle),
          reason: 'the page');
      final facades = find.byKey(const ValueKey('youtube-facade'));
      await app.waitFor(() => facades.evaluate().length == 3,
          reason: 'a video, a Short and a playlist; the link in a sentence '
              'stays a link');
      expect(
          find.textContaining('on YouTube', findRichText: true),
          findsOneWidget,
          reason: 'the link inside a sentence stays text');

      final launcher = RecordingLauncher();
      final systemLauncher = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = launcher;
      try {
        await app.tester.tap(facades.first);
        await app.waitFor(() => launcher.launches.isNotEmpty,
            reason: 'the tap to open YouTube');
        expect(launcher.launches.single.url,
            'https://www.youtube.com/watch?v=${AnnouncementFixtures.videoId}'
            '&t=65s',
            reason: 'the canonical link, from the start time');
        expect(launcher.launches.single.mode,
            PreferredLaunchMode.externalNonBrowserApplication,
            reason: 'in the YouTube app');
        await app.waitFor(() => !app.audio.playbackState.value.playing,
            reason: 'the radio to pause for the video');
        await app.waitFor(
            () => server.announcementEvents.any((e) =>
                e['slug'] == AnnouncementFixtures.videoSlug &&
                e['type'] == 'video_play' &&
                e['provider'] == 'youtube' &&
                e['kind'] == 'video'),
            reason: 'video_play to reach the backend',
            timeout: const Duration(seconds: 15));

        // Back from YouTube, the radio stays paused, even where a return
        // starts the last station (iOS, with auto-start on).
        await app.turnOnAutoStart();
        await app.leaveAndReturn();
        await app.pumpFor(const Duration(seconds: 10));
        expect(app.audio.playbackState.value.playing, isFalse,
            reason: 'no autoplay after the video; ${app.describe()}');

        // Without the YouTube app, the browser opens it.
        launcher
          ..launches.clear()
          ..appInstalled = false;
        await app.tester.ensureVisible(facades.at(1));
        await app.tester.tap(facades.at(1));
        await app.waitFor(() => launcher.launches.length == 2,
            reason: 'the app, then the browser');
        expect(
            launcher.launches.map((launch) => launch.mode),
            [
              PreferredLaunchMode.externalNonBrowserApplication,
              PreferredLaunchMode.externalApplication,
            ],
            reason: 'the browser when no app takes it');
        expect(launcher.launches.last.url,
            'https://www.youtube.com/shorts/${AnnouncementFixtures.shortId}');
      } finally {
        UrlLauncherPlatform.instance = systemLauncher;
      }
      expect(find.byType(WebViewWidget), findsNothing,
          reason: 'no player inside the app');
    });

    announcementTest('a launch forgets what the removed "later" button kept',
        (app) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('announcements_snoozed',
          '{"${AnnouncementFixtures.verseSlug}":"2099-01-01T00:00:00Z"}');
      await app.coldStartAnnouncements();
      await app.waitFor(() => !prefs.containsKey('announcements_snoozed'),
          reason: 'the old snoozes to be removed');
    });

    /// Serves [items] in this order with [settings] and starts the app
    /// again, so the card starts afresh.
    Future<void> launchWith(
      RadioApp app,
      List<Map<String, Object?>> items, {
      Map<String, Object?> settings = const {},
    }) async {
      // A healthy API, even when this test is the run's first, slow one.
      server.conditions.restore();
      server
        ..announcements.clear()
        ..announcements.addAll(items)
        ..announcementSettings = {
          ...FakeRadioServer.defaultAnnouncementSettings,
          ...settings,
        };
      await app.coldStartAnnouncements();
      await app.waitFor(() => app.showsText('1 din ${items.length}'),
          reason: 'the card; ${app.describe()}');
      // A list that comes after the first frame grows the card in: let it
      // settle before tapping its buttons.
      await app.pumpFor(const Duration(seconds: 1));
    }

    /// Lets [duration] pass and expects the card still on [counter].
    Future<void> expectStays(RadioApp app, String counter,
        {Duration duration = const Duration(seconds: 7),
        required String reason}) async {
      await app.pumpFor(duration);
      expect(app.showsText(counter), isTrue,
          reason: '$reason; ${app.describe()}');
    }

    Future<void> waitForCounter(RadioApp app, String counter,
            {required String reason}) =>
        app.waitFor(() => app.showsText(counter),
            reason: reason, timeout: const Duration(seconds: 8));

    announcementTest("the card keeps the server's order", (app) async {
      // Positions 1, 2, 0: the list order wins over any number.
      await launchWith(app, [
        AnnouncementFixtures.concert(),
        AnnouncementFixtures.newest(),
        AnnouncementFixtures.verse(),
      ]);
      expect(app.showsText(AnnouncementFixtures.concertTitle), isTrue);
      await app.tapKey('announcement-next');
      await app.waitFor(() => app.showsText('2 din 3'), reason: 'the second');
      expect(app.showsText(AnnouncementFixtures.newestTitle), isTrue);
      await app.tapKey('announcement-next');
      await app.waitFor(() => app.showsText('3 din 3'), reason: 'the third');
      expect(app.showsText(AnnouncementFixtures.verseTitle), isTrue);
    });

    announcementTest(
        'rotate starts each launch one further, in the server\'s order, and '
        'paging stops at the ends of that turn', (app) async {
      final items = [
        AnnouncementFixtures.verse(),
        AnnouncementFixtures.concert(),
        AnnouncementFixtures.newest(),
      ];
      const rotate = {'rotation_mode': 'rotate'};
      await launchWith(app, items, settings: rotate);
      expect(app.showsText(AnnouncementFixtures.verseTitle), isTrue,
          reason: 'the first launch starts at the first');

      await launchWith(app, items, settings: rotate);
      expect(app.showsText(AnnouncementFixtures.concertTitle), isTrue,
          reason: 'the next launch starts at the second');
      // The turn: concert, newest, verse; the ends stop.
      await app.tapKey('announcement-previous');
      expect(app.showsText('1 din 3'), isTrue,
          reason: 'nothing before the start of the turn');
      for (final (counter, title) in [
        ('2 din 3', AnnouncementFixtures.newestTitle),
        ('3 din 3', AnnouncementFixtures.verseTitle),
      ]) {
        await app.tapKey('announcement-next');
        await app.waitFor(
            () => app.showsText(counter) && app.showsText(title),
            reason: '$counter, "$title"');
      }
      await app.tapKey('announcement-next');
      expect(app.showsText('3 din 3'), isTrue,
          reason: 'nothing after the end of the turn');
    });

    announcementTest(
        'autoplay moves on by itself to the last one, at the tallest '
        "one's height all along", (app) async {
      await launchWith(app, [
        AnnouncementFixtures.titleOnly(),
        AnnouncementFixtures.concert(),
        AnnouncementFixtures.verse(),
      ], settings: {'autoplay_seconds': 3});
      final card = RadioApp.announcementCard;
      final height = app.tester.getSize(card).height;
      await waitForCounter(app, '2 din 3', reason: 'the first move');
      await app.pumpFor(const Duration(seconds: 1));
      expect(app.tester.getSize(card).height, height,
          reason: 'the title-only card was already as tall as the tallest');
      await waitForCounter(app, '3 din 3', reason: 'the second move');
      await expectStays(app, '3 din 3',
          reason: 'it stops at the last one, without going round');
      expect(app.tester.getSize(card).height, height);
    });

    announcementTest(
        'autoplay waits while the card is touched, half off the screen or '
        'the app is in the background', (app) async {
      await launchWith(app, [
        AnnouncementFixtures.verse(),
        AnnouncementFixtures.concert(),
        AnnouncementFixtures.newest(),
        AnnouncementFixtures.titleOnly(),
      ], settings: {'autoplay_seconds': 3});

      final touch = await app.tester
          .startGesture(app.tester.getCenter(RadioApp.announcementCard));
      await expectStays(app, '1 din 4', reason: 'a finger on the card');
      await touch.cancel();
      await waitForCounter(app, '2 din 4', reason: 'on once let go');

      await app.scrollStations();
      await app.pumpFor(const Duration(seconds: 7));
      await app.scrollStations(up: true);
      // Read once back: off the screen the counter can't be found.
      expect(app.showsText('2 din 4'), isTrue,
          reason: 'no move while the card was scrolled away');
      await waitForCounter(app, '3 din 4', reason: 'on once back');

      app.goToBackground();
      await expectStays(app, '3 din 4', reason: 'the app in the background');
      await app.comeBack();
      await waitForCounter(app, '4 din 4', reason: 'on once back');
    });

    announcementTest(
        'autoplay stops for good after a swipe, an arrow or "Ascunde", and '
        'is off with reduced motion', (app) async {
      final items = [
        AnnouncementFixtures.verse(),
        AnnouncementFixtures.concert(),
        AnnouncementFixtures.newest(),
      ];
      const autoplay = {'autoplay_seconds': 3};

      await launchWith(app, items, settings: autoplay);
      await app.swipeAnnouncement();
      await expectStays(app, '2 din 3', reason: 'stopped by a swipe');

      await launchWith(app, items, settings: autoplay);
      await app.tapKey('announcement-next');
      await expectStays(app, '2 din 3', reason: 'stopped by an arrow');

      final dispatcher = app.tester.platformDispatcher;
      dispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      try {
        await launchWith(app, items, settings: autoplay);
        await expectStays(app, '1 din 3', reason: 'off with reduced motion');
      } finally {
        dispatcher.clearAccessibilityFeaturesTestValue();
      }

      // Last: the closed announcement stays closed.
      await launchWith(app, items, settings: autoplay);
      await app.tapDismiss();
      await app.waitFor(() => app.showsText('1 din 2'), reason: 'closed');
      await expectStays(app, '1 din 2', reason: 'stopped by "Ascunde"');
    });

    announcementTest(
        'the card swipes and steps with its buttons, and a tap opens its page',
        (app) async {
      await showAnnouncements(app);
      expect(app.showsText('1 din 2'), isTrue, reason: app.describe());

      await app.swipeAnnouncement();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.concertTitle),
          reason: 'the second announcement after a swipe');
      expect(app.showsText('2 din 2'), isTrue);

      // The buttons stop at the ends: the way out is disabled there, and a
      // tap on it changes nothing.
      final semantics = app.tester.ensureSemantics();
      void expectEnabled(String button, bool enabled) => expect(
            app.tester.getSemantics(find.byKey(ValueKey(button))),
            isSemantics(hasEnabledState: true, isEnabled: enabled),
            reason: '$button is ${enabled ? 'enabled' : 'disabled'}',
          );
      Future<void> step(String button, String counter, String title) async {
        await app.tapKey(button);
        await app.waitFor(
            () => app.showsText(counter) && app.showsText(title),
            reason: '$button to show $counter, "$title"');
      }

      expectEnabled('announcement-next', false);
      expectEnabled('announcement-previous', true);
      await step('announcement-next', '2 din 2',
          AnnouncementFixtures.concertTitle);
      await step('announcement-previous', '1 din 2',
          AnnouncementFixtures.verseTitle);
      expectEnabled('announcement-previous', false);
      expectEnabled('announcement-next', true);
      await step('announcement-previous', '1 din 2',
          AnnouncementFixtures.verseTitle);
      await step('announcement-next', '2 din 2',
          AnnouncementFixtures.concertTitle);
      semantics.dispose();

      await app.tapText(AnnouncementFixtures.concertTitle);
      await app.waitFor(() => app.showsText(AnnouncementFixtures.pageTitle),
          reason: 'the announcement page to open');
      await app.waitFor(() => app.showsText(AnnouncementFixtures.pageHeading),
          reason: 'the page markdown, from the single announcement');
      await app.waitFor(
          () => server.announcementEvents.any((e) =>
              e['slug'] == AnnouncementFixtures.concertSlug &&
              e['type'] == 'clicked' &&
              e['target'] == 'card'),
          reason: 'the card tap to reach the backend');

      await app.tapTooltip('Înapoi');
      await app.waitFor(() => app.showsText(AnnouncementFixtures.concertTitle),
          reason: 'Home with the card, after the page');
    });

    announcementTest('"Ascunde" hides an announcement for good', (app) async {
      await showAnnouncements(app);

      await app.tapDismiss();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.concertTitle),
          reason: 'the next announcement after hiding the first');
      await app.tapDismiss();
      await app.waitFor(() => RadioApp.announcementCard.evaluate().isEmpty,
          reason: 'the card to go once both are hidden');

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        prefs.getStringList('announcements_dismissed'),
        containsAll(
            [AnnouncementFixtures.verseSlug, AnnouncementFixtures.concertSlug]),
        reason: 'the hidden slugs are saved on the device',
      );

      await app.coldStartAnnouncements();
      await app.pumpFor(const Duration(seconds: 3));
      expect(RadioApp.announcementCard, findsNothing,
          reason: 'a hidden announcement does not come back');
      await app.waitFor(
          () =>
              server.announcementEvents
                  .where((e) => e['type'] == 'dismissed')
                  .length ==
              2,
          reason: 'both dismissals to reach the backend',
          timeout: const Duration(seconds: 15));
    });

    announcementTest(
        "a station's announcements show on its mini player and in a sheet",
        (app) async {
      server.announcements
          .add(AnnouncementFixtures.stationNews(Stations.alpha.slug));
      await app.pullToRefresh();
      expect(RadioApp.announcementCard, findsNothing,
          reason: 'a station announcement never goes in the home card');

      await app.tapStation(Stations.alpha);
      await app.waitFor(() => app.findsKey('station-announcements-strip'),
          reason: 'the unread strip on top of the mini player');
      expect(app.findsKey('station-announcements-bell'), isTrue,
          reason: 'the bell on the mini player');

      await app.tapKey('station-announcements-strip');
      await app.waitFor(() => app.showsText('Anunțuri ale postului'),
          reason: "the station's announcements sheet");
      expect(app.showsText(AnnouncementFixtures.stationNewsTitle), isTrue);

      await app.tapTooltip('Închide');
      await app.waitFor(() => !app.findsKey('station-announcements-strip'),
          reason: 'the strip to go once the announcements were opened');
      expect(app.findsKey('station-announcements-bell'), isTrue,
          reason: 'the bell stays');
    });

    announcementTest('a form opens in a sheet, themed like the app',
        (app) async {
      server.announcements.add(AnnouncementFixtures.poll());
      await app.pullToRefresh();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.formButton),
          reason: 'the poll card');

      await app.tapText(AnnouncementFixtures.formButton);
      await app.waitFor(
          () => server.requests.any((r) =>
              r.path ==
                  '/api/v1/forms/${AnnouncementFixtures.formSlug}/page/' &&
              {'dark', 'light'}.contains(r.query['theme'])),
          reason: 'the form page to load with the theme');
      final page = server.requests.lastWhere((r) =>
          r.path == '/api/v1/forms/${AnnouncementFixtures.formSlug}/page/');
      expect(page.query.containsKey('device_id'), isFalse,
          reason: 'the device stays in the fragment, out of the cache key');
      await app.waitFor(() => !app.findsKey('form-skeleton'),
          reason: 'the page to say it is ready',
          timeout: const Duration(seconds: 30));

      await app.tapTooltip('Închide');
      await app.waitFor(() => app.showsText(AnnouncementFixtures.formButton),
          reason: 'Home again after closing the form');
    });
  });

  group('Settings', () {
    test("the contact button opens the website's contact page, with the "
        "app's details", (app) async {
      final launcher = RecordingLauncher();
      final systemLauncher = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = launcher;
      try {
        await app.openSettings();
        await app.tapSetting('Contactează-ne');
        await app.waitFor(() => launcher.launches.isNotEmpty,
            reason: 'the contact page to open');
        final page = Uri.parse(launcher.launches.single.url);
        expect(page.host, 'www.radiocrestin.ro');
        expect(page.path, '/contact/');
        expect(page.queryParameters['source'], 'app');
        expect(page.queryParameters['platform'],
            Platform.isIOS ? 'ios' : 'android');
        expect(page.queryParameters['app_version'], isNotEmpty);
        expect(launcher.launches.single.mode,
            PreferredLaunchMode.externalApplication);
      } finally {
        UrlLauncherPlatform.instance = systemLauncher;
      }
    });
  });

  group('Playlist stations', () {
    test('a YouTube playlist item loads the whole playlist', (app) async {
      await app.tapStation(Stations.youtubePlaylist);
      await app.waitFor(
          () =>
              app.audio.currentStation.valueOrNull?.slug ==
              Stations.youtubePlaylist.slug,
          reason: 'the playlist station to start');
      await app.openFullPlayer();
      final player = find.byType(YoutubePlayer);
      await app.waitFor(() => player.evaluate().isNotEmpty,
          reason: 'the YouTube player in the full player');
      final youtube = app.tester.widget<YoutubePlayer>(player).controller;

      // A player given the list ID as an array stays blank, with no videos.
      var videos = <String>[];
      final end = DateTime.now().add(const Duration(seconds: 45));
      while (videos.isEmpty && DateTime.now().isBefore(end)) {
        await app.pumpFor(const Duration(seconds: 1));
        try {
          videos = await youtube.playlist;
        } on ArgumentError {
          // Not loaded yet: the player answers null.
        }
      }
      expect(videos, isNotEmpty,
          reason: "the player holds the playlist's videos");
    });
  });

  // Last: it leaves the app in the background, where the tests above could
  // not drive it. Android doesn't let an app bring itself back.
  group('Leaving the app', () {
    test('BACK on Home leaves the station playing in the background',
        skip: !Platform.isAndroid, (app) async {
      await app.expectPlaying(Stations.alpha,
          since: await app.tapStation(Stations.alpha));

      final leftAt = await app.pressBack();
      await app.expectAudioAdvances(const Duration(seconds: 8));
      expect(
          server.mediaBytesSent(Stations.alpha, since: leftAt), greaterThan(0),
          reason: 'the stream kept coming in the background');
      expect(app.lifecycle, AppLifecycleState.paused,
          reason: 'the app waits in the background, not closed');
    });
  });
}

/// Forgets every announcement the device kept or was told, as a fresh
/// install, and starts the announcements anew.
Future<void> _forgetAnnouncements(RadioApp app) async {
  final prefs = await SharedPreferences.getInstance();
  for (final key in prefs.getKeys().toList()) {
    if (key.startsWith('announcements_')) await prefs.remove(key);
  }
  await app.coldStartAnnouncements();
}
