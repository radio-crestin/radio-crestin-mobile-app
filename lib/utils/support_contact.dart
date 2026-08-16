/// Builds the WhatsApp "contact us" deep link the app offers when playback
/// fails, prefilled with the diagnostics support needs to answer without a
/// back-and-forth.
///
/// Pure and dependency-free so the format is unit-testable AND can be mirrored
/// byte-for-byte by the TV side, which cannot launch WhatsApp and instead
/// encodes the very same URL into a QR code (`lib/tv/pages/tv_settings.dart`).
library;

/// The support WhatsApp number, already used by Settings and the quick actions.
const String kSupportWhatsAppNumber = '40766338046';

/// Machine-readable header line: `[RadioCrestin/<platform>/v<version>/<id>]`.
///
/// Same shape as the Settings and Android TV messages, so every inbound report
/// can be parsed the same way whatever screen it came from.
String buildSupportDiagnosticsHeader({
  required String platform,
  required String appVersion,
  required String buildNumber,
  required String deviceId,
}) {
  final version = buildNumber.isEmpty ? 'v$appVersion' : 'v$appVersion($buildNumber)';
  return '[RadioCrestin/$platform/$version/$deviceId]';
}

/// The Romanian message body for a PLAYBACK problem.
///
/// Only the lines we actually know are included — an unknown item or stream is
/// omitted rather than sent as an empty field.
String buildPlaybackIssueMessage({
  required String platform,
  required String appVersion,
  required String buildNumber,
  required String deviceId,
  String? stationTitle,
  String? stationSlug,
  String? itemTitle,
  String? streamUrl,
}) {
  final header = buildSupportDiagnosticsHeader(
    platform: platform,
    appVersion: appVersion,
    buildNumber: buildNumber,
    deviceId: deviceId,
  );
  final lines = <String>[
    header,
    '',
    'Bună ziua, am o problemă cu redarea.',
    '',
  ];
  final station = [
    if (stationTitle != null && stationTitle.isNotEmpty) stationTitle,
    if (stationSlug != null && stationSlug.isNotEmpty) '($stationSlug)',
  ].join(' ');
  if (station.isNotEmpty) lines.add('Post: $station');
  if (itemTitle != null && itemTitle.isNotEmpty) lines.add('Element: $itemTitle');
  if (streamUrl != null && streamUrl.isNotEmpty) lines.add('Sursă: $streamUrl');
  return lines.join('\n');
}

/// The `wa.me` link for [message], URL-encoded into the `text` parameter.
Uri buildSupportWhatsAppUri({required String message}) => Uri.parse(
      'https://wa.me/$kSupportWhatsAppNumber'
      '?text=${Uri.encodeComponent(message)}',
    );

/// Convenience: [buildPlaybackIssueMessage] straight into [buildSupportWhatsAppUri].
Uri buildPlaybackIssueWhatsAppUri({
  required String platform,
  required String appVersion,
  required String buildNumber,
  required String deviceId,
  String? stationTitle,
  String? stationSlug,
  String? itemTitle,
  String? streamUrl,
}) =>
    buildSupportWhatsAppUri(
      message: buildPlaybackIssueMessage(
        platform: platform,
        appVersion: appVersion,
        buildNumber: buildNumber,
        deviceId: deviceId,
        stationTitle: stationTitle,
        stationSlug: stationSlug,
        itemTitle: itemTitle,
        streamUrl: streamUrl,
      ),
    );

/// Whether the player should offer the "Contactează-ne" affordance.
///
/// ONLY in trouble: a video that fell back to audio-only, or an item that
/// failed to play. Never during healthy playback — the button must read as a
/// way out of a problem, not as permanent chrome.
bool showPlaybackTroubleContact({
  required bool audioOnlyFallback,
  required bool itemFailed,
}) =>
    audioOnlyFallback || itemFailed;
