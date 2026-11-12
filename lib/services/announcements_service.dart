import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../globals.dart' as globals;
import 'analytics_service.dart';
import 'announcement.dart';
import 'announcement_store.dart';

/// What happened to an announcement, as `POST /announcements/events/` and
/// PostHog (`announcement_<name>`) name it.
enum AnnouncementEvent {
  impression,
  clicked,
  secondaryClicked,
  dismissed,
  pageViewed,
  pushOpened;

  String get apiName => switch (this) {
        secondaryClicked => 'secondary_clicked',
        pageViewed => 'page_viewed',
        pushOpened => 'push_opened',
        _ => name,
      };
}

/// The announcements the home card shows, in the order it shows them.
class AnnouncementList {
  const AnnouncementList(this.items, this.settings);

  static const empty = AnnouncementList([], AnnouncementSettings());

  final List<Announcement> items;
  final AnnouncementSettings settings;
}

/// Loads the announcements for this device, keeps what the device
/// remembers about them, and reports what the listener does with them.
///
/// The contract with the backend and the website is the announcements
/// spec: the list's filtering and order happen here, the targeting on the
/// server.
class AnnouncementsService with WidgetsBindingObserver {
  AnnouncementsService({
    required SharedPreferences prefs,
    this.pushEnabled = true,
    http.Client? client,
  })  : _store = AnnouncementStore(prefs),
        _client = client ?? http.Client() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Whether announcement pushes are handled (off in the e2e tests).
  final bool pushEnabled;

  final AnnouncementStore _store;
  final http.Client _client;

  /// The announcements to show now; empty when there are none.
  final BehaviorSubject<AnnouncementList> announcements =
      BehaviorSubject.seeded(AnnouncementList.empty);

  /// The events not sent yet.
  final List<Map<String, Object?>> _queue = [];
  Timer? _flushTimer;
  bool _flushing = false;

  static const _flushInterval = Duration(seconds: 5);
  static const _maxEventsPerRequest = 100;
  static const _maxQueuedEvents = 500;
  static const _timeout = Duration(seconds: 8);

  /// Slugs whose impression this launch already reported.
  final Set<String> _seenThisLaunch = {};

  /// Slugs taken off the screen for this launch only (hide_after_seconds,
  /// or closed while not dismissible on the server).
  final Set<String> _hiddenThisLaunch = {};

  /// The first announcement this launch's rotation picked, kept across
  /// refreshes so the card does not jump on every resume.
  String? _rotationStartSlug;

  static String get platform => Platform.isIOS ? 'ios' : 'android';

  static String get _locale =>
      ui.PlatformDispatcher.instance.locale.toLanguageTag();

  // ── Loading ────────────────────────────────────────────────────────────

  /// Fetches the list and publishes what this device should see. Keeps
  /// the last list when the request fails.
  Future<void> load() async {
    final uri = Uri.parse('${CONSTANTS.ANNOUNCEMENTS_URL}/').replace(
      queryParameters: {
        'device_id': globals.deviceId,
        'platform': platform,
        'app_version': globals.appVersion,
        'locale': _locale,
      },
    );
    try {
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode != 200) {
        developer.log('Announcements: HTTP ${response.statusCode}');
        return;
      }
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is! Map) return;
      final items = (json['announcements'] as List? ?? const [])
          .map(Announcement.fromJson)
          .whereType<Announcement>()
          .toList();
      final settings = AnnouncementSettings.fromJson(json['settings']);
      final shown = await _ordered(_showable(items), settings.rotationMode);
      announcements.add(AnnouncementList(shown, settings));
    } catch (e) {
      developer.log('Announcements: load failed: $e');
    }
  }

  /// Fetches one announcement (a push tap), or null when it is gone.
  Future<Announcement?> fetch(String slug) async {
    final path = Uri.encodeComponent(slug);
    try {
      final response = await _client
          .get(Uri.parse('${CONSTANTS.ANNOUNCEMENTS_URL}/$path/'))
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      return Announcement.fromJson(jsonDecode(utf8.decode(response.bodyBytes)));
    } catch (e) {
      developer.log('Announcements: fetch $slug failed: $e');
      return null;
    }
  }

  List<Announcement> _showable(List<Announcement> items) {
    final now = DateTime.now();
    final dismissed = _store.dismissed;
    return items.where((item) {
      final max = item.maxImpressions;
      final ended = item.endsAt != null && item.endsAt!.isBefore(now);
      return !ended &&
          !dismissed.contains(item.slug) &&
          !_hiddenThisLaunch.contains(item.slug) &&
          !_store.isSnoozed(item.slug, now) &&
          (max == null || max <= 0 || _store.impressions(item.slug) < max);
    }).toList();
  }

  /// Puts the item this launch starts with first, as [mode] says.
  Future<List<Announcement>> _ordered(
    List<Announcement> items,
    RotationMode mode,
  ) async {
    if (items.length < 2 || mode == RotationMode.fixed) return items;
    final start = _rotationStartSlug == null
        ? await _pickStart(items, mode)
        : items.indexWhere((item) => item.slug == _rotationStartSlug);
    if (start <= 0) return items;
    _rotationStartSlug = items[start].slug;
    return switch (mode) {
      RotationMode.rotate => [...items.skip(start), ...items.take(start)],
      _ => [items[start], ...items.where((item) => item != items[start])],
    };
  }

  Future<int> _pickStart(List<Announcement> items, RotationMode mode) async {
    final start = mode == RotationMode.rotate
        ? _store.rotationCursor % items.length
        : Random().nextInt(items.length);
    if (mode == RotationMode.rotate) await _store.advanceRotationCursor();
    _rotationStartSlug = items[start].slug;
    return start;
  }

  // ── What the listener does ─────────────────────────────────────────────

  /// Counts the card as seen, once per slug per launch.
  void recordImpression(Announcement item, int position) {
    if (!_seenThisLaunch.add(item.slug)) return;
    unawaited(_store.countImpression(item.slug));
    report(AnnouncementEvent.impression, item, position);
  }

  /// Hides [item] for good on this device (the X, or "close").
  Future<void> dismiss(Announcement item, int position) async {
    _removeFromScreen(item.slug);
    report(AnnouncementEvent.dismissed, item, position);
    await _store.dismiss(item.slug);
  }

  /// Hides [item] for [days] days ("later").
  Future<void> snooze(Announcement item, int days) async {
    _removeFromScreen(item.slug);
    await _store.snooze(item.slug, DateTime.now().add(Duration(days: days)));
  }

  /// Takes [item] off the screen until the next launch.
  void hideForThisLaunch(Announcement item) {
    _hiddenThisLaunch.add(item.slug);
    _removeFromScreen(item.slug);
  }

  void _removeFromScreen(String slug) {
    final current = announcements.value;
    announcements.add(AnnouncementList(
      current.items.where((item) => item.slug != slug).toList(),
      current.settings,
    ));
  }

  /// Queues [event] for the backend and sends it to PostHog. A click is
  /// sent at once, as it may take the listener out of the app.
  void report(AnnouncementEvent event, Announcement item, int position) {
    AnalyticsService.instance.capture('announcement_${event.apiName}', {
      'announcement_slug': item.slug,
      'announcement_category': item.category.slug,
      'action_type': item.actionType,
      'position': position,
      'platform': platform,
    });
    if (_queue.length >= _maxQueuedEvents) _queue.removeAt(0);
    _queue.add({
      'slug': item.slug,
      'type': event.apiName,
      'position': position,
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    final urgent = event == AnnouncementEvent.clicked ||
        event == AnnouncementEvent.secondaryClicked ||
        event == AnnouncementEvent.pushOpened;
    if (urgent) {
      unawaited(flush());
    } else {
      _flushTimer ??= Timer(_flushInterval, flush);
    }
  }

  /// Sends the queued events; those that fail wait for the next flush.
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_flushing || _queue.isEmpty) return;
    _flushing = true;
    final batch = _queue.take(_maxEventsPerRequest).toList();
    _queue.removeRange(0, batch.length);
    try {
      final response = await _client
          .post(
            Uri.parse(CONSTANTS.ANNOUNCEMENT_EVENTS_URL),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'device_id': globals.deviceId,
              'platform': platform,
              'app_version': globals.appVersion,
              'locale': _locale,
              'events': batch,
            }),
          )
          .timeout(_timeout);
      if (response.statusCode >= 500) _queue.insertAll(0, batch);
    } catch (e) {
      developer.log('Announcements: events not sent: $e');
      _queue.insertAll(0, batch);
    } finally {
      _flushing = false;
    }
    if (_queue.isNotEmpty) _flushTimer ??= Timer(_flushInterval, flush);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(flush());
  }
}
