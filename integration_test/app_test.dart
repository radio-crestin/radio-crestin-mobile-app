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
    /// Serves the two fixtures and launches Home anew, which loads them.
    Future<void> showAnnouncements(RadioApp app) async {
      server.announcements
        ..add(AnnouncementFixtures.verse())
        ..add(AnnouncementFixtures.concert());
      // Long enough that the card does not move on by itself mid-test.
      server.announcementSettings = const {
        'rotation_mode': 'fixed',
        'autoplay_seconds': 120,
      };
      await app.relaunch();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.verseTitle),
          reason: 'the announcement card to show');
    }

    test('the card swipes to the next one, whose button opens its page',
        (app) async {
      await showAnnouncements(app);
      expect(app.showsText('1 din 2'), isTrue, reason: app.describe());

      await app.swipeAnnouncement();
      await app.waitFor(() => app.showsText(AnnouncementFixtures.concertTitle),
          reason: 'the second announcement after a swipe');
      expect(app.showsText('2 din 2'), isTrue);

      await app.tapText(AnnouncementFixtures.concertButton);
      await app.waitFor(() => app.showsText(AnnouncementFixtures.pageTitle),
          reason: 'the announcement page to open');
      expect(app.showsText(AnnouncementFixtures.pageHeading), isTrue,
          reason: 'the page renders its markdown');
      await app.waitFor(
          () => server.announcementEvents.any((e) =>
              e['slug'] == AnnouncementFixtures.concertSlug &&
              e['type'] == 'clicked'),
          reason: 'the click to reach the backend');

      await app.tapTooltip('Înapoi');
      await app.waitFor(() => app.showsText(AnnouncementFixtures.concertTitle),
          reason: 'Home with the card, after the page');
    });

    test('a closed announcement stays closed after a relaunch', (app) async {
      await showAnnouncements(app);

      await app.tapTooltip('Închide');
      await app.waitFor(() => app.showsText(AnnouncementFixtures.concertTitle),
          reason: 'the next announcement after closing the first');
      await app.tapTooltip('Închide');
      await app.waitFor(() => RadioApp.announcementCard.evaluate().isEmpty,
          reason: 'the card to go once both are closed');

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        prefs.getStringList('announcements_dismissed'),
        containsAll(
            [AnnouncementFixtures.verseSlug, AnnouncementFixtures.concertSlug]),
        reason: 'the closed slugs are saved on the device',
      );

      await app.relaunch();
      await app.pumpFor(const Duration(seconds: 3));
      expect(app.showsText(AnnouncementFixtures.verseTitle), isFalse,
          reason: 'a closed announcement does not come back');
      expect(RadioApp.announcementCard, findsNothing);
      await app.waitFor(
          () =>
              server.announcementEvents
                  .where((e) => e['type'] == 'dismissed')
                  .length ==
              2,
          reason: 'both dismissals to reach the backend',
          timeout: const Duration(seconds: 15));
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
      expect(server.mediaBytesSent(Stations.alpha, since: leftAt),
          greaterThan(0),
          reason: 'the stream kept coming in the background');
      expect(app.lifecycle, AppLifecycleState.paused,
          reason: 'the app waits in the background, not closed');
    });
  });
}
