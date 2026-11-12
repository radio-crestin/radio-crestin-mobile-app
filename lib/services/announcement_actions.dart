import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:url_launcher/url_launcher.dart';

import '../appAudioHandler.dart';
import '../globals.dart' as globals;
import '../pages/AnnouncementPage.dart';
import '../types/Station.dart';
import '../widgets/announcement_form_sheet.dart';
import '../widgets/bottom_toast.dart';
import 'announcement.dart';
import 'announcement_copy.dart';
import 'station_data_service.dart';

/// Runs what an announcement's button does, as the announcements spec's
/// action table says for Android and iOS.
///
/// Links come from the admin, so only safe ones open: http(s), mailto and
/// tel in a browser or app, and `intent:` URIs through Android. Anything
/// else (`javascript:`, `data:`, `file:`, …) is ignored.
class AnnouncementActions {
  AnnouncementActions._();

  /// Runs [action] of [item]; tells the listener when a link can't open.
  static Future<void> run(Announcement item, AnnouncementAction action) async {
    final done = switch (action.type) {
      AnnouncementActionType.external =>
        openLink(action.url, LaunchMode.externalApplication),
      AnnouncementActionType.inAppBrowser =>
        openLink(action.url, LaunchMode.inAppBrowserView),
      AnnouncementActionType.androidIntent => _openAndroidIntent(action),
      AnnouncementActionType.page => _openPage(item),
      AnnouncementActionType.station => _playStation(action.stationSlug),
      AnnouncementActionType.form => _openForm(item, action.formSlug),
      AnnouncementActionType.none => Future.value(true),
    };
    if (!await done) _showFailure();
  }

  static const _linkSchemes = {'http', 'https', 'mailto', 'tel'};

  /// [url] parsed, when its scheme is safe to hand to a browser or app.
  static Uri? safeLink(String? url) {
    final uri = url == null ? null : Uri.tryParse(url.trim());
    if (uri == null || !_linkSchemes.contains(uri.scheme.toLowerCase())) {
      return null;
    }
    return uri;
  }

  /// Opens [url] if it is a safe link; false when it could not open.
  static Future<bool> openLink(String? url, LaunchMode mode) async {
    final uri = safeLink(url);
    if (uri == null) {
      developer.log('Announcement: link refused: $url');
      return false;
    }
    // Only a web page opens in the in-app browser.
    final inApp = mode == LaunchMode.inAppBrowserView &&
        (uri.scheme == 'http' || uri.scheme == 'https');
    if (await _launch(uri, inApp ? mode : LaunchMode.externalApplication)) {
      return true;
    }
    // No Custom Tabs browser: the system browser still opens it.
    return inApp && await _launch(uri, LaunchMode.externalApplication);
  }

  static Future<bool> _launch(Uri uri, LaunchMode mode) async {
    try {
      return await launchUrl(uri, mode: mode);
    } catch (e) {
      developer.log('Announcement: cannot open $uri: $e');
      return false;
    }
  }

  /// Launches the intent on Android; elsewhere, or when no app takes it,
  /// opens its fallback link.
  static Future<bool> _openAndroidIntent(AnnouncementAction action) async {
    final intentUri = action.androidIntentUri?.trim();
    if (Platform.isAndroid &&
        intentUri != null &&
        intentUri.toLowerCase().startsWith('intent:')) {
      try {
        await AndroidIntent.parseAndLaunch(intentUri);
        return true;
      } catch (e) {
        developer.log('Announcement: intent failed, using fallback: $e');
      }
    }
    return openLink(
        action.fallbackUrl ?? action.url, LaunchMode.externalApplication);
  }

  static Future<bool> _openPage(Announcement item) async {
    final navigator = globals.navigatorKey.currentState;
    if (navigator == null || item.page == null) return false;
    unawaited(navigator.push(AnnouncementPage.route(item)));
    return true;
  }

  static Future<bool> _openForm(Announcement item, String? formSlug) async {
    final context = globals.navigatorKey.currentContext;
    if (context == null || formSlug == null) return false;
    unawaited(AnnouncementFormSheet.show(
      context,
      formSlug: formSlug,
      announcementSlug: item.slug,
    ));
    return true;
  }

  static Future<bool> _playStation(String? slug) async {
    if (slug == null) return false;
    final station = await findStation(slug);
    if (station == null) return false;
    await GetIt.instance<AppAudioHandler>()
        .playStation(station, fromFavorites: false);
    return true;
  }

  /// [slug]'s station, waiting a little for the list on a cold start.
  static Future<Station?> findStation(String slug) async {
    final stations = GetIt.instance<StationDataService>().stations;
    final list = stations.value.isNotEmpty
        ? stations.value
        : await stations.stream
            .firstWhere((list) => list.isNotEmpty)
            .timeout(const Duration(seconds: 5), onTimeout: () => []);
    return list.where((station) => station.slug == slug).firstOrNull;
  }

  static void _showFailure() {
    final context = globals.navigatorKey.currentContext;
    if (context == null) return;
    showBottomToast(
      context,
      title: AnnouncementCopy.linkFailed,
      message: AnnouncementCopy.linkFailedHint,
      icon: Icons.link_off_rounded,
      isError: true,
    );
  }
}
