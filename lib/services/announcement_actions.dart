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
import '../widgets/bottom_toast.dart';
import 'announcement.dart';
import 'announcement_copy.dart';
import 'station_data_service.dart';

/// Runs what an announcement's button does, as the announcements spec's
/// action table says for Android and iOS.
class AnnouncementActions {
  AnnouncementActions._();

  /// Runs [action] of [item]; tells the listener when a link can't open.
  static Future<void> run(Announcement item, AnnouncementAction action) async {
    final done = switch (action.type) {
      AnnouncementActionType.external =>
        _open(action.url, LaunchMode.externalApplication),
      AnnouncementActionType.inAppBrowser =>
        _open(action.url, LaunchMode.inAppBrowserView),
      AnnouncementActionType.androidIntent => _openAndroidIntent(action),
      AnnouncementActionType.page => _openPage(item),
      AnnouncementActionType.station => _playStation(action.stationSlug),
      AnnouncementActionType.none => Future.value(true),
    };
    if (!await done) _showFailure();
  }

  static Future<bool> _open(String? url, LaunchMode mode) async {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) return false;
    try {
      if (await launchUrl(uri, mode: mode)) return true;
    } catch (e) {
      developer.log('Announcement: cannot open $url: $e');
    }
    // An in-app browser may be missing (no Custom Tabs browser): the
    // system browser still opens it.
    if (mode == LaunchMode.externalApplication) return false;
    return _open(url, LaunchMode.externalApplication);
  }

  /// Launches the intent on Android; elsewhere, or when no app takes it,
  /// opens its fallback link.
  static Future<bool> _openAndroidIntent(AnnouncementAction action) async {
    final intentUri = action.androidIntentUri;
    if (Platform.isAndroid && intentUri != null) {
      try {
        await AndroidIntent.parseAndLaunch(intentUri);
        return true;
      } catch (e) {
        developer.log('Announcement: intent failed, using fallback: $e');
      }
    }
    return _open(
        action.fallbackUrl ?? action.url, LaunchMode.externalApplication);
  }

  static Future<bool> _openPage(Announcement item) async {
    final navigator = globals.navigatorKey.currentState;
    if (navigator == null || item.page == null) return false;
    unawaited(navigator.push(AnnouncementPage.route(item)));
    return true;
  }

  static Future<bool> _playStation(String? slug) async {
    if (slug == null) return false;
    final station = await _findStation(slug);
    if (station == null) return false;
    await GetIt.instance<AppAudioHandler>()
        .playStation(station, fromFavorites: false);
    return true;
  }

  /// [slug]'s station, waiting a little for the list on a cold start.
  static Future<Station?> _findStation(String slug) async {
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
