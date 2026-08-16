import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/utils/support_contact.dart';
import 'package:radio_crestin/widgets/contact_support_button.dart';

/// The "Contactează-ne" affordance shown when playback fails.
///
/// It must (a) only ever appear in a trouble state, (b) open WhatsApp on a link
/// that already carries the diagnostics — station, item, device id, version —
/// so the user never has to describe the failure, and (c) keep a format the TV
/// side can mirror into its QR code.
void main() {
  Uri sampleUri() => buildPlaybackIssueWhatsAppUri(
        platform: 'ios 18.2',
        appVersion: '1.3.2',
        buildNumber: '56',
        deviceId: 'device-abc-123',
        stationTitle: 'Radio Filadelfia',
        stationSlug: 'radio-filadelfia',
        itemTitle: 'BCEV Live #1',
        streamUrl: 'https://cdn.example/live.m3u8',
      );

  group('buildPlaybackIssueMessage', () {
    test('carries the diagnostics header and every known field', () {
      final message = buildPlaybackIssueMessage(
        platform: 'ios 18.2',
        appVersion: '1.3.2',
        buildNumber: '56',
        deviceId: 'device-abc-123',
        stationTitle: 'Radio Filadelfia',
        stationSlug: 'radio-filadelfia',
        itemTitle: 'BCEV Live #1',
        streamUrl: 'https://cdn.example/live.m3u8',
      );

      expect(message,
          startsWith('[RadioCrestin/ios 18.2/v1.3.2(56)/device-abc-123]'));
      expect(message, contains('am o problemă cu redarea'));
      expect(message, contains('Post: Radio Filadelfia (radio-filadelfia)'));
      expect(message, contains('Element: BCEV Live #1'));
      expect(message, contains('Sursă: https://cdn.example/live.m3u8'));
    });

    test('omits fields it does not know instead of sending blanks', () {
      final message = buildPlaybackIssueMessage(
        platform: 'android 15',
        appVersion: '1.3.2',
        buildNumber: '',
        deviceId: 'd1',
        stationSlug: 'radio-x',
      );

      expect(message, contains('[RadioCrestin/android 15/v1.3.2/d1]'));
      expect(message, contains('Post: (radio-x)'));
      expect(message, isNot(contains('Element:')));
      expect(message, isNot(contains('Sursă:')));
    });
  });

  group('buildSupportWhatsAppUri', () {
    test('URL-encodes the message into wa.me ?text=', () {
      final uri = sampleUri();

      expect(uri.host, 'wa.me');
      expect(uri.path, '/$kSupportWhatsAppNumber');
      // Decoded through the query parameter, the message survives intact.
      expect(uri.queryParameters['text'], contains('radio-filadelfia'));
      expect(uri.queryParameters['text'], contains('device-abc-123'));
      // And the raw URL is encoded — no literal spaces or newlines.
      expect(uri.toString(), isNot(contains(' ')));
      expect(uri.toString(), isNot(contains('\n')));
      expect(uri.toString(), contains('device-abc-123'));
      expect(uri.toString(), contains('radio-filadelfia'));
    });
  });

  group('showPlaybackTroubleContact', () {
    test('only in a trouble state', () {
      expect(
          showPlaybackTroubleContact(
              audioOnlyFallback: false, itemFailed: false),
          isFalse,
          reason: 'never during healthy playback');
      expect(
          showPlaybackTroubleContact(audioOnlyFallback: true, itemFailed: false),
          isTrue);
      expect(
          showPlaybackTroubleContact(audioOnlyFallback: false, itemFailed: true),
          isTrue);
    });
  });

  group('ContactSupportButton', () {
    testWidgets('renders the label and launches the prefilled link',
        (tester) async {
      // Arrange: a fake launcher stands in for url_launcher.
      final launched = <Uri>[];
      final uri = sampleUri();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: ContactSupportButton(
              uri: uri,
              launcher: (u) async {
                launched.add(u);
                return true;
              },
            ),
          ),
        ),
      ));
      await tester.pump();

      // Assert: the error state shows the button…
      expect(find.text('Contactează-ne'), findsOneWidget);

      // Act.
      await tester.tap(find.byType(ContactSupportButton));
      await tester.pump();

      // Assert: …and tapping it opens the diagnostics-carrying link.
      expect(launched, hasLength(1));
      final opened = launched.single.toString();
      expect(opened, contains(Uri.encodeComponent('device-abc-123')));
      expect(opened, contains(Uri.encodeComponent('radio-filadelfia')));
    });

    testWidgets('a launcher failure never throws at the user', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: ContactSupportButton(
              uri: sampleUri(),
              launcher: (_) async => throw Exception('no WhatsApp installed'),
            ),
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.byType(ContactSupportButton));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
