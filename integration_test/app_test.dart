import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:radio_crestin/appAudioHandler.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'harness/announcement_fixtures.dart';
import 'harness/fake_radio_server.dart';
import 'harness/network_conditions.dart';
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
        'a new announcement waits for the next launch, then shows at once',
        (app) async {
      server.announcements.add(AnnouncementFixtures.verse());
      await app.relaunch();
      await app.waitFor(
          () => server.requests.any(
              (r) => r.path == '/api/v1/announcements/' && r.bytesSent > 0),
          reason: 'the list to be fetched in the background');
      await app.pumpFor(const Duration(seconds: 2));
      expect(RadioApp.announcementCard, findsNothing,
          reason: 'nothing pops in above the stations while they show');

      // The API is down at the next launch: the card can only come from
      // the list the device kept.
      server.conditions.set(
        const Link(outage: Outage.serverError),
        origins: [Origin.api],
      );
      await app.coldStartAnnouncements();
      expect(app.showsText(AnnouncementFixtures.verseTitle), isTrue,
          reason: 'the kept list shows in the first frame; ${app.describe()}');
    });

    announcementTest('the card swipes, and a tap on it opens its page',
        (app) async {
      await showAnnouncements(app);
      expect(app.showsText('1 din 2'), isTrue, reason: app.describe());

      await app.swipeAnnouncement();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.concertTitle),
          reason: 'the second announcement after a swipe');
      expect(app.showsText('2 din 2'), isTrue);

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
