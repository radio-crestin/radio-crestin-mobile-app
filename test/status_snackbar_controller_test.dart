import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/appAudioHandler.dart' show ConnectionErrorReason;
import 'package:radio_crestin/services/network_service.dart'
    show ConnectionStatus;
import 'package:radio_crestin/widgets/status_snackbar_controller.dart';

import 'helpers/station_factory.dart';

const _wifiNoInternet = 'Ești conectat la WiFi, dar rețeaua nu are internet.';
const _mobileNoInternet =
    'Ești conectat la date mobile, dar rețeaua nu are internet.';
const _resumes = 'Redarea pornește singură când revine internetul.';

// Timers are driven by `testWidgets`' fake clock (`tester.pump(duration)`),
// so these state tests run instantly and deterministically.
void main() {
  late StatusSnackbarController controller;
  late int notified;

  setUp(() {
    controller = StatusSnackbarController();
    notified = 0;
    controller.addListener(() => notified++);
  });
  tearDown(() => controller.dispose());

  void goOffline({bool onMobileData = false}) => controller
      .updateNetwork(ConnectionStatus.offline, onMobileData: onMobileData);
  void loseInternet({bool onMobileData = false}) => controller
      .updateNetwork(ConnectionStatus.noInternet, onMobileData: onMobileData);
  void goOnline({bool onMobileData = false}) => controller
      .updateNetwork(ConnectionStatus.online, onMobileData: onMobileData);

  bool showError({
    ConnectionErrorReason reason = ConnectionErrorReason.timeout,
    String title = 'Radio Vocea Evangheliei',
    int? stationId,
  }) =>
      controller.showStationError(
        stationTitle: title,
        reason: reason,
        station: stationId == null
            ? null
            : StationFactory.createStation(
                id: stationId, slug: 's$stationId', title: title),
      );

  group('stationErrorReason', () {
    test('gives short, human copy for every reason', () {
      expect(stationErrorReason(ConnectionErrorReason.timeout),
          'Conexiunea a expirat');
      expect(stationErrorReason(ConnectionErrorReason.network),
          'Verifică conexiunea la internet');
      expect(stationErrorReason(ConnectionErrorReason.httpError),
          'Stația nu este disponibilă momentan');
      expect(stationErrorReason(ConnectionErrorReason.unknown),
          'Nu răspunde momentan');
    });
  });

  group('StatusMessage', () {
    test('no internet on WiFi or mobile data says which network', () {
      const wifi = StatusMessage.offline(status: ConnectionStatus.noInternet);
      const mobile = StatusMessage.offline(
        status: ConnectionStatus.noInternet,
        onMobileData: true,
      );

      expect(wifi.title, 'Nu ai conexiune la internet');
      expect(wifi.body, _wifiNoInternet);
      expect(mobile.body, _mobileNoInternet);
    });

    test('no internet: the network explanation wins over the playback one', () {
      const message = StatusMessage.offline(
        status: ConnectionStatus.noInternet,
        playIntent: true,
      );

      expect(message.body, _wifiNoInternet);
    });

    test('no network: playback resumes by itself while something plays', () {
      const message = StatusMessage.offline(
        status: ConnectionStatus.offline,
        playIntent: true,
        // Mobile data says nothing without a network.
        onMobileData: true,
      );

      expect(message.body, _resumes);
    });

    test('no network and nothing playing: the title alone', () {
      const message = StatusMessage.offline(status: ConnectionStatus.offline);

      expect(message.title, 'Nu ai conexiune la internet');
      expect(message.body, isNull);
    });

    test('back-online suffix only while playback resumes', () {
      expect(const StatusMessage.backOnline(resuming: true).body,
          'redarea continuă');
      expect(const StatusMessage.backOnline(resuming: false).body, isNull);
    });

    test('compares by content and station', () {
      final a = StatusMessage.stationError(
        stationTitle: 'A',
        reason: ConnectionErrorReason.timeout,
        station: StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      );
      final sameContent = StatusMessage.stationError(
        stationTitle: 'A',
        reason: ConnectionErrorReason.timeout,
        station: StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      );
      final otherStation = StatusMessage.stationError(
        stationTitle: 'A',
        reason: ConnectionErrorReason.timeout,
        station: StationFactory.createStation(id: 2, slug: 'b', title: 'A'),
      );

      expect(a, sameContent);
      expect(a.hashCode, sameContent.hashCode);
      expect(a, isNot(otherStation));
      expect(a.contentKey, otherStation.contentKey);
    });

    test('only a station error can be dismissed', () {
      expect(
        const StatusMessage.offline(status: ConnectionStatus.offline)
            .isDismissible,
        isFalse,
      );
      expect(const StatusMessage.backOnline(resuming: true).isDismissible,
          isFalse);
      expect(
        StatusMessage.stationError(
          stationTitle: 'A',
          reason: ConnectionErrorReason.unknown,
        ).isDismissible,
        isTrue,
      );
    });
  });

  group('offline', () {
    test('starts online, with nothing to show', () {
      expect(controller.isOffline, isFalse);
      expect(controller.message, isNull);
    });

    test('no network: offline, title only while nothing plays', () {
      goOffline();

      expect(controller.isOffline, isTrue);
      expect(controller.message,
          const StatusMessage.offline(status: ConnectionStatus.offline));
      expect(controller.message?.body, isNull);
      expect(notified, 1);
    });

    test('no network while a station plays: it resumes by itself', () {
      controller.playIntent = true;

      goOffline();

      expect(controller.message?.body, _resumes);
    });

    test('a network without internet is offline too, and says why', () {
      controller.playIntent = true;

      loseInternet();
      expect(controller.isOffline, isTrue);
      expect(controller.message?.body, _wifiNoInternet);

      loseInternet(onMobileData: true);
      expect(controller.message?.body, _mobileNoInternet);
    });

    testWidgets('no network <-> no internet only changes the explanation',
        (tester) async {
      controller.playIntent = true;
      goOffline();

      loseInternet();
      expect(controller.message?.body, _wifiNoInternet);
      goOffline();
      expect(controller.message?.body, _resumes);

      // Never a "back online" in between, now or later.
      await tester.pump(const Duration(seconds: 3));
      expect(controller.message?.kind, StatusKind.offline);
      expect(notified, 3);
    });

    test('follows the play intent live', () {
      goOffline();
      expect(controller.message?.body, isNull);

      controller.playIntent = true;
      expect(controller.message?.body, _resumes);

      controller.playIntent = false;
      expect(controller.message?.body, isNull);
      expect(notified, 3);
    });

    test('changes that show nothing new notify no one', () {
      controller.playIntent = true;
      goOnline(onMobileData: true);
      goOnline();
      controller.updatePlayback(playIntent: true, playingReady: true);

      expect(notified, 0);
    });

    test('a start online is not a return: no back-online status', () {
      goOnline();

      expect(controller.message, isNull);
    });

    testWidgets('cannot be dismissed: it stays while offline', (tester) async {
      goOffline();

      controller.clearError();
      await tester.pump(const Duration(minutes: 5));

      expect(controller.message?.kind, StatusKind.offline);
    });
  });

  group('back online', () {
    testWidgets('shows for exactly 3s after offline, then nothing',
        (tester) async {
      goOffline();

      goOnline();
      expect(
          controller.message, const StatusMessage.backOnline(resuming: false));

      await tester.pump(const Duration(milliseconds: 2999));
      expect(controller.message?.kind, StatusKind.backOnline);
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.message, isNull);
    });

    testWidgets('also after a network without internet', (tester) async {
      loseInternet();

      goOnline();

      expect(controller.message?.kind, StatusKind.backOnline);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('says playback continues only while something plays',
        (tester) async {
      controller.playIntent = true;
      goOffline();
      goOnline();

      expect(
          controller.message, const StatusMessage.backOnline(resuming: true));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('going offline again ends it', (tester) async {
      goOffline();
      goOnline();

      goOffline();

      expect(controller.message?.kind, StatusKind.offline);
      await tester.pump(const Duration(seconds: 3));
      expect(controller.message?.kind, StatusKind.offline);
    });

    testWidgets('cannot be dismissed early', (tester) async {
      goOffline();
      goOnline();

      controller.clearError();

      expect(controller.message?.kind, StatusKind.backOnline);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('station error', () {
    testWidgets('shows, then clears itself after exactly 6s', (tester) async {
      expect(showError(), isTrue);

      expect(controller.message?.kind, StatusKind.stationError);
      expect(controller.message?.title, 'Radio Vocea Evangheliei');
      expect(controller.message?.body, 'Conexiunea a expirat');

      await tester.pump(const Duration(milliseconds: 5999));
      expect(controller.message?.kind, StatusKind.stationError);
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.message, isNull);
    });

    testWidgets('a newer error replaces the older and restarts the timer',
        (tester) async {
      showError(title: 'A');
      await tester.pump(const Duration(seconds: 4));

      showError(title: 'B', reason: ConnectionErrorReason.httpError);
      await tester.pump(const Duration(seconds: 4));

      expect(controller.message?.title, 'B');
      expect(controller.message?.body, 'Stația nu este disponibilă momentan');
      await tester.pump(const Duration(seconds: 2));
      expect(controller.message, isNull);
    });

    testWidgets('is held while a screen reader runs', (tester) async {
      controller.holdErrors = true;
      showError();

      await tester.pump(const Duration(seconds: 30));
      expect(controller.message?.kind, StatusKind.stationError);

      // Released: a fresh 6s from now.
      controller.holdErrors = false;
      await tester.pump(const Duration(milliseconds: 5999));
      expect(controller.message?.kind, StatusKind.stationError);
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.message, isNull);
    });

    for (final (name, lose) in [
      ('no network', () => goOffline()),
      ('a network without internet', () => loseInternet()),
    ]) {
      test('is never shown while offline: $name', () {
        lose();

        expect(showError(), isFalse);

        expect(controller.message?.kind, StatusKind.offline);
      });

      test('ends when the device goes offline: $name', () {
        showError();

        lose();

        expect(controller.message?.kind, StatusKind.offline);
        // Not back when the internet returns either: back online is next.
        goOnline();
        expect(controller.message?.kind, StatusKind.backOnline);
      });
    }

    testWidgets('outranks back online, which shows after it if still due',
        (tester) async {
      goOffline();
      goOnline();

      showError();
      expect(controller.message?.kind, StatusKind.stationError);

      controller.clearError();
      expect(controller.message?.kind, StatusKind.backOnline);
      await tester.pump(const Duration(seconds: 3));
    });

    test('a swipe or a retry clears it', () {
      showError();

      controller.clearError();

      expect(controller.message, isNull);
    });

    test('names the station even when the error has no name', () {
      showError(title: '');

      expect(controller.message?.title, 'Stația radio');
    });

    test('ends when audio starts playing again', () {
      controller.updatePlayback(playIntent: true, playingReady: false);
      showError();

      controller.updatePlayback(playIntent: true, playingReady: true);

      expect(controller.message, isNull);
    });

    test(
        'a newer error while audio keeps playing stays: only a return to '
        'playing ends it', () {
      controller.updatePlayback(playIntent: true, playingReady: true);
      showError();

      controller.updatePlayback(playIntent: true, playingReady: true);
      expect(controller.message?.kind, StatusKind.stationError);

      controller
        ..updatePlayback(playIntent: true, playingReady: false)
        ..updatePlayback(playIntent: true, playingReady: true);
      expect(controller.message, isNull);
    });

    test('ends when another station becomes current, not on the same one', () {
      showError(stationId: 1);

      controller.updateCurrentStation(1);
      expect(controller.message?.kind, StatusKind.stationError);

      controller.updateCurrentStation(2);
      expect(controller.message, isNull);
    });
  });

  group('playback', () {
    test('the play intent follows playback', () {
      goOffline();

      controller.updatePlayback(playIntent: true, playingReady: false);
      expect(controller.message?.body, _resumes);

      controller.updatePlayback(playIntent: false, playingReady: false);
      expect(controller.message?.body, isNull);
    });
  });
}
