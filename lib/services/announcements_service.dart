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
import 'image_cache_service.dart';

/// What happened to an announcement, as `POST /announcements/events/` and
/// PostHog (`announcement_<name>`) name it.
enum AnnouncementEvent {
  impression,
  clicked,
  dismissed,
  pageViewed,
  pushOpened,
  videoPlay;

  String get apiName => switch (this) {
        pageViewed => 'page_viewed',
        pushOpened => 'push_opened',
        videoPlay => 'video_play',
        _ => name,
      };
}

/// What was tapped for a `clicked` event: the whole card or its button.
enum ClickTarget { card, button }

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
/// The list is the same for everyone (Cloudflare caches it); this service
/// keeps the last one and has the home card ready for the first frame:
/// from the kept list, or on a first launch from the API if it answers
/// within [startupWait]. It checks each announcement's filters on the
/// device. Every refresh shows the list as it is: the card grows in or
/// shrinks away smoothly, and the announcement on screen stays there.
class AnnouncementsService with WidgetsBindingObserver {
  AnnouncementsService({
    required SharedPreferences prefs,
    this.pushEnabled = true,
    http.Client? client,
  })  : _store = AnnouncementStore(prefs),
        _client = client ?? http.Client() {
    WidgetsBinding.instance.addObserver(this);
    _feed = _Feed.parse(_store.feed);
    _publishAll();
    unawaited(_store.forgetRetired());
  }

  /// Whether announcement pushes are handled (off in the e2e tests).
  final bool pushEnabled;

  final AnnouncementStore _store;
  final http.Client _client;

  /// The home card's announcements; empty when there are none.
  final BehaviorSubject<AnnouncementList> announcements =
      BehaviorSubject.seeded(AnnouncementList.empty);

  /// Every station announcement this device may see; [forStation] picks
  /// those of one station.
  final BehaviorSubject<List<Announcement>> stationAnnouncements =
      BehaviorSubject.seeded(const []);

  /// The station announcements whose sheet was opened on this device.
  late final BehaviorSubject<Set<String>> seen =
      BehaviorSubject.seeded(_store.seen);

  _Feed _feed = _Feed.empty;

  /// The longest a launch without a kept list waits for the API before
  /// the home screen shows; a later answer still shows this launch.
  static const startupWait = Duration(milliseconds: 1500);

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

  /// Slugs taken off the screen for this launch only (hide_after_seconds).
  final Set<String> _hiddenThisLaunch = {};

  /// The first announcement this launch's rotation picked, kept across
  /// refreshes so the card does not jump.
  String? _rotationStartSlug;

  /// Single announcements already fetched (their page markdown).
  final Map<String, Announcement> _details = {};

  static String get platform => Platform.isIOS ? 'ios' : 'android';

  static String get _locale =>
      ui.PlatformDispatcher.instance.locale.toLanguageTag();

  /// The device's country, from `/devices/register/` or an events reply.
  String? get country => _store.country;

  Future<void> saveCountry(String? country) => _store.saveCountry(country);

  /// Whether an admin's preview link is on (unpublished announcements).
  bool get isPreviewing => _store.previewToken != null;

  // ── Loading ────────────────────────────────────────────────────────────

  /// Readies the home card before the app's first frame, alongside the
  /// stations: the kept list shows at once while the API is asked; with no
  /// kept list (a first launch, a preview) the API gets up to [wait].
  Future<void> loadAtStartup({Duration wait = startupWait}) async {
    // The app version is known now; the filters need it.
    _publishAll();
    final fetching = refresh();
    if (_store.feed != null && _store.previewToken == null) return;
    await fetching.timeout(wait, onTimeout: () {});
  }

  /// Fetches the list, keeps it for the next launch and shows it.
  ///
  /// Asked for while another fetch runs (a pull-to-refresh during the
  /// startup one), it fetches once more after it, so the list is never
  /// older than the request.
  Future<void> refresh() {
    final running = _inFlight;
    if (running != null) return _next ??= _refreshAfter(running);
    return _inFlight = _refresh().whenComplete(() => _inFlight = null);
  }

  Future<void>? _inFlight;
  Future<void>? _next;

  Future<void> _refreshAfter(Future<void> running) async {
    try {
      await running;
    } catch (_) {
      // Its failure is its own; this fetch starts anyway.
    }
    _next = null;
    await refresh();
  }

  Future<void> _refresh() async {
    final preview = _store.previewToken;
    final fetched =
        preview == null ? await _fetchCached() : await _fetchPreview(preview);
    if (fetched == null || _disposed) return;
    _feed = fetched;
    _publishAll();
  }

  /// The list from Cloudflare's cache (the kept one when unchanged, 304),
  /// or null when unreachable.
  Future<_Feed?> _fetchCached() async {
    final etag = _store.feedEtag;
    try {
      final response = await _client.get(
        Uri.parse('${CONSTANTS.ANNOUNCEMENTS_URL}/'),
        headers: {
          if (etag != null && _store.feed != null) 'If-None-Match': etag,
        },
      ).timeout(_timeout);
      // Unchanged: the list kept on the device is the current one, even
      // when this launch has not read it yet.
      if (response.statusCode == 304) return _Feed.parse(_store.feed);
      if (response.statusCode != 200) return null;
      final body = utf8.decode(response.bodyBytes);
      final feed = _Feed.parse(body);
      await _store.saveFeed(body, response.headers['etag']);
      _prefetchImages(feed);
      return feed;
    } catch (e) {
      developer.log('Announcements: list not fetched: $e');
      return null;
    }
  }

  /// The list with unpublished announcements, never cached; a refused
  /// token ends the preview.
  Future<_Feed?> _fetchPreview(String token) async {
    final uri = Uri.parse('${CONSTANTS.ANNOUNCEMENTS_URL}/')
        .replace(queryParameters: {'preview': token});
    try {
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode == 403) {
        await _store.savePreviewToken(null);
        return _Feed.parse(_store.feed);
      }
      if (response.statusCode != 200) return null;
      return _Feed.parse(utf8.decode(response.bodyBytes));
    } catch (e) {
      developer.log('Announcements: preview not fetched: $e');
      return null;
    }
  }

  /// Starts (or with an empty [token], ends) an admin's preview, from the
  /// `radiocrestin://anunturi-preview?token=…` link.
  Future<void> setPreviewToken(String? token) async {
    await _store.savePreviewToken(token);
    _details.clear();
    _rotationStartSlug = null;
    await refresh();
  }

  /// One announcement with its page's markdown (a page, a push tap), or
  /// null when it is gone.
  Future<Announcement?> fetch(String slug) async {
    final cached = _details[slug];
    if (cached != null) return cached;
    final preview = _store.previewToken;
    final uri = Uri.parse(
      '${CONSTANTS.ANNOUNCEMENTS_URL}/${Uri.encodeComponent(slug)}/',
    ).replace(queryParameters: preview == null ? null : {'preview': preview});
    try {
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final item =
          Announcement.fromJson(jsonDecode(utf8.decode(response.bodyBytes)));
      if (item != null) _details[slug] = item;
      return item;
    } catch (e) {
      developer.log('Announcements: $slug not fetched: $e');
      return null;
    }
  }

  void _prefetchImages(_Feed feed) {
    if (!_imageCacheReady) return;
    for (final item in feed.items) {
      for (final url in [item.iconUrl, item.page?.coverImageUrl]) {
        if (url != null) {
          unawaited(ImageCacheService.instance.getOrDownload(url));
        }
      }
    }
  }

  static bool get _imageCacheReady {
    try {
      ImageCacheService.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── What shows ─────────────────────────────────────────────────────────

  /// Shows the feed as it is now: new and removed announcements included.
  /// The order keeps this launch's first announcement first, so the card
  /// on screen does not change under the listener.
  void _publishAll() {
    final now = DateTime.now();
    final home = _feed.items
        .where((item) => item.placement == AnnouncementPlacement.home)
        .where((item) => _isShowable(item, now))
        .take(_feed.settings.maxPerLoad ?? _feed.items.length)
        .toList();
    announcements.add(AnnouncementList(_ordered(home), _feed.settings));
    _publishStations(now);
  }

  /// Station announcements sit in a sheet, not in the page's flow: they
  /// follow the feed at once.
  void _publishStations(DateTime now) => stationAnnouncements.add(_feed.items
      .where((item) => item.placement == AnnouncementPlacement.station)
      .where((item) => _isShowable(item, now))
      .toList());

  /// The announcements of the station [slug].
  List<Announcement> forStation(String? slug) => slug == null
      ? const []
      : stationAnnouncements.value
          .where((item) => item.stationSlugs.contains(slug))
          .toList();

  bool _isShowable(Announcement item, DateTime now) {
    final max = item.maxImpressions;
    return item.isLiveAt(now) &&
        item.filters.matches(
          platform: platform,
          locale: _locale,
          appVersion: globals.appVersion,
          country: _store.country,
        ) &&
        !_store.dismissed.contains(item.slug) &&
        !_hiddenThisLaunch.contains(item.slug) &&
        // Seen this launch: its last allowed impression stays on screen.
        (max == null ||
            max <= 0 ||
            _seenThisLaunch.contains(item.slug) ||
            _store.impressions(item.slug) < max);
  }

  /// The server's order (never re-sorted). Rotate and random turn it to
  /// start with this launch's first announcement: k…n-1, then 0…k-1. That
  /// start is kept across refreshes, so the card does not jump.
  List<Announcement> _ordered(List<Announcement> items) {
    final mode = _feed.settings.rotationMode;
    if (items.length < 2 || mode == RotationMode.fixed) return items;
    var start = items.indexWhere((item) => item.slug == _rotationStartSlug);
    if (start < 0) start = _pickStart(items.length, mode);
    _rotationStartSlug = items[start].slug;
    return [...items.skip(start), ...items.take(start)];
  }

  int _pickStart(int count, RotationMode mode) {
    if (mode == RotationMode.random) return Random().nextInt(count);
    final start = _store.rotationCursor % count;
    unawaited(_store.advanceRotationCursor());
    return start;
  }

  // ── What the listener does ─────────────────────────────────────────────

  /// Counts the card as seen, once per slug per launch.
  void recordImpression(Announcement item, int position, {String? station}) {
    if (!_seenThisLaunch.add(item.slug)) return;
    unawaited(_store.countImpression(item.slug));
    report(AnnouncementEvent.impression, item, position, station: station);
  }

  /// Hides [item] for good on this device ("Ascunde").
  Future<void> dismiss(Announcement item, int position,
      {String? station}) async {
    report(AnnouncementEvent.dismissed, item, position, station: station);
    await _store.dismiss(item.slug);
    _removeFromScreen(item.slug);
  }

  /// Takes [item] off the screen until the next launch.
  void hideForThisLaunch(Announcement item) {
    _hiddenThisLaunch.add(item.slug);
    _removeFromScreen(item.slug);
  }

  /// Marks the station announcements [items] as opened.
  Future<void> markSeen(Iterable<Announcement> items) async {
    final slugs = items.map((item) => item.slug).toSet();
    if (seen.value.containsAll(slugs)) return;
    seen.add({...seen.value, ...slugs});
    await _store.markSeen(slugs);
  }

  void _removeFromScreen(String slug) {
    final current = announcements.value;
    announcements.add(AnnouncementList(
      current.items.where((item) => item.slug != slug).toList(),
      current.settings,
    ));
    stationAnnouncements.add(
        stationAnnouncements.value.where((item) => item.slug != slug).toList());
  }

  /// Queues [event] for the backend and sends it to PostHog. A click is
  /// sent at once, as it may take the listener out of the app.
  ///
  /// [station]: the station playing, for a station announcement.
  /// [details]: what else the event carries (a video's provider and kind).
  void report(
    AnnouncementEvent event,
    Announcement item,
    int position, {
    ClickTarget? target,
    String? station,
    Map<String, String> details = const {},
  }) {
    final stationSlug =
        item.placement == AnnouncementPlacement.station ? station : null;
    AnalyticsService.instance.capture('announcement_${event.apiName}', {
      'announcement_slug': item.slug,
      'announcement_category': item.category.slug,
      'action_type': item.actionType,
      'position': position,
      'platform': platform,
      'placement': item.placement.name,
      if (stationSlug != null) 'station_slug': stationSlug,
      if (target != null) 'target': target.name,
      ...details,
    });
    if (_queue.length >= _maxQueuedEvents) _queue.removeAt(0);
    _queue.add({
      'slug': item.slug,
      'type': event.apiName,
      'position': position,
      'target': target?.name,
      'placement': item.placement.name,
      'station_slug': stationSlug,
      ...details,
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    final urgent = event == AnnouncementEvent.clicked ||
        event == AnnouncementEvent.pushOpened;
    if (urgent) {
      unawaited(flush());
    } else {
      _flushTimer ??= Timer(_flushInterval, flush);
    }
  }

  /// Sends the queued events; those that fail wait for the next flush.
  /// The reply also tells the device's country.
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
      if (response.statusCode == 200) await _saveCountryFrom(response.body);
    } catch (e) {
      developer.log('Announcements: events not sent: $e');
      _queue.insertAll(0, batch);
    } finally {
      _flushing = false;
    }
    if (_queue.isNotEmpty) _flushTimer ??= Timer(_flushInterval, flush);
  }

  Future<void> _saveCountryFrom(String body) async {
    try {
      final json = jsonDecode(body);
      if (json is Map && json['country'] is String) {
        await _store.saveCountry(json['country'] as String);
      }
    } on FormatException {
      // An empty or non-JSON reply carries no country.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        _wasBackgrounded = true;
        unawaited(flush());
      case AppLifecycleState.resumed:
        if (!_wasBackgrounded) return;
        _wasBackgrounded = false;
        unawaited(refresh());
      default:
        break;
    }
  }

  bool _wasBackgrounded = false;

  bool _disposed = false;

  /// Stops listening to the app's lifecycle and shows nothing more (a
  /// test's simulated restart).
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
  }
}

/// A list as the API sends it: its settings and announcements.
class _Feed {
  const _Feed(this.items, this.settings);

  static const empty = _Feed([], AnnouncementSettings());

  final List<Announcement> items;
  final AnnouncementSettings settings;

  static _Feed parse(String? body) {
    if (body == null) return empty;
    try {
      final json = jsonDecode(body);
      if (json is! Map) return empty;
      return _Feed(
        (json['announcements'] as List? ?? const [])
            .map(Announcement.fromJson)
            .whereType<Announcement>()
            .toList(),
        AnnouncementSettings.fromJson(json['settings']),
      );
    } on FormatException {
      return empty;
    }
  }
}
