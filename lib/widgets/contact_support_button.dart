import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../globals.dart' as globals;
import '../services/analytics_service.dart';
import '../utils/support_contact.dart';

/// How a [ContactSupportButton] opens the link. Injected by tests.
typedef SupportLinkLauncher = Future<bool> Function(Uri uri);

/// Compact "Contactează-ne" affordance shown ONLY in playback-error contexts.
///
/// Opens WhatsApp (external application) on a link prefilled with the failing
/// station / item and the device diagnostics, so the user does not have to
/// describe the problem and support does not have to ask what broke — see
/// [buildPlaybackIssueWhatsAppUri].
class ContactSupportButton extends StatelessWidget {
  const ContactSupportButton({
    super.key,
    required this.uri,
    this.launcher,
    this.dense = true,
  });

  /// The prefilled `wa.me` link. Built by the caller so the diagnostics reflect
  /// exactly what failed.
  final Uri uri;

  /// Overrides the launch mechanism (tests inject a fake).
  final SupportLinkLauncher? launcher;

  /// Small overlay variant (on the media surface) vs a roomier inline one.
  final bool dense;

  static Future<bool> _launchExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  Future<void> _open() async {
    AnalyticsService.instance.capture('support_contact_opened', {
      'source': 'playback_error',
    });
    try {
      await (launcher ?? _launchExternal)(uri);
    } catch (_) {
      // WhatsApp missing / no browser — nothing useful to do, and an error
      // toast on top of a playback error would only add noise.
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Contactează-ne pe WhatsApp',
      child: Tooltip(
        message: 'Contactează-ne pe WhatsApp',
        child: Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.92),
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _open,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: dense ? 10.0 : 14.0,
                vertical: dense ? 6.0 : 10.0,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.support_agent_rounded,
                      size: dense ? 16 : 18, color: scheme.onSurface),
                  const SizedBox(width: 6),
                  Text(
                    'Contactează-ne',
                    style: TextStyle(
                      fontSize: dense ? 12 : 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The prefilled support link for a playback problem on the current station /
/// item, filled in from the app's runtime globals and the host platform.
Uri playbackIssueSupportUri({
  String? stationTitle,
  String? stationSlug,
  String? itemTitle,
  String? streamUrl,
}) =>
    buildPlaybackIssueWhatsAppUri(
      platform: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      appVersion: globals.appVersion,
      buildNumber: globals.buildNumber,
      deviceId: globals.deviceId,
      stationTitle: stationTitle,
      stationSlug: stationSlug,
      itemTitle: itemTitle,
      streamUrl: streamUrl,
    );
