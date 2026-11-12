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
/// keeps the last one, shows the home card from it at once on a cold
/// start, refreshes it in the background with `If-None-Match`, and checks
/// each announcement's filters on the device. So that the card never
/// appears, vanishes or changes height under the listener's finger, new
/// and removed announcements wait for the next cold start, a resume after
/// [_staleAfter] in the background, or a pull-to-refresh.
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
  DateTime? _backgroundedAt;

  /// A resume after this long in the background shows new and removed
  /// announcements, as a cold start does.
  static const _staleAfter = Duration(minutes: 30);

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

  /// Fetches the list in the background and keeps it for the next launch.
  ///
  /// With [showChanges] (pull-to-refresh, a long resume, a preview) new and
  /// removed announcements show at once; otherwise only changes that keep
  /// every card's height apply now.
  Future<void> refresh({bool showChanges = false}) {
    _showChangesAfterRefresh |= showChanges;
    return _inFlight ??= _refresh().whenComplete(() => _inFlight = null);
  }

  Future<void>? _inFlight;

  /// Whether a refresh asked for while another ran wants new and removed
  /// announcements shown (a pull-to-refresh during the startup refresh).
  bool _showChangesAfterRefresh = false;

  Future<void> _refresh() async {
    final preview = _store.previewToken;
    final fetched =
        preview == null ? await _fetchCached() : await _fetchPreview(preview);
    if (fetched != null) _feed = fetched;
    final showChanges = _showChangesAfterRefresh || preview != null;
    _showChangesAfterRefresh = false;
    if (showChanges) {
      _publishAll();
    } else if (fetched != null) {
      _publishContentChanges();
    }
  }

  /// The list from Cloudflare's cache, or null when unchanged (304) or
  /// unreachable.
  Future<_Feed?> _fetchCached() async {
    final etag = _store.feedEtag;
    try {
      final response = await _client.get(
        Uri.parse('${CONSTANTS.ANNOUNCEMENTS_URL}/'),
        headers: {
          if (etag != null && _store.feed != null) 'If-None-Match': etag,
        },
      ).timeout(_timeout);
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
    await refresh(showChanges: true);
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
        if (url != null)
          unawaited(ImageCacheService.instance.getOrDownload(url));
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

  /// Updates the cards on screen whose height cannot change; anything else
  /// waits for the next cold start or long resume.
  void _publishContentChanges() {
    final fresh = {for (final item in _feed.items) item.slug: item};
    final shown = announcements.value;
    final updated = [
      for (final item in shown.items)
        if (fresh[item.slug] case final next?
            when next.layoutSignature == item.layoutSignature)
          next
        else
          item,
    ];
    announcements.add(AnnouncementList(updated, shown.settings));
    _publishStations(DateTime.now());
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
        !_store.isSnoozed(item.slug, now) &&
        (max == null || max <= 0 || _store.impressions(item.slug) < max);
  }

  /// Puts the item this launch starts with first, as the rotation mode
  /// says. Fixed keeps the server's order.
  List<Announcement> _ordered(List<Announcement> items) {
    final mode = _feed.settings.rotationMode;
    if (items.length < 2 || mode == RotationMode.fixed) return items;
    var start = items.indexWhere((item) => item.slug == _rotationStartSlug);
    if (start < 0) start = _pickStart(items, mode);
    _rotationStartSlug = items[start].slug;
    return switch (mode) {
      RotationMode.rotate => [...items.skip(start), ...items.take(start)],
      _ => [items[start], ...items.where((item) => item != items[start])],
    };
  }

  int _pickStart(List<Announcement> items, RotationMode mode) {
    if (mode == RotationMode.random) return Random().nextInt(items.length);
    final start = _store.rotationCursor % items.length;
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

  /// Hides [item] for good on this device ("Ascunde", or "close").
  Future<void> dismiss(Announcement item, int position,
      {String? station}) async {
    report(AnnouncementEvent.dismissed, item, position, station: station);
    await _store.dismiss(item.slug);
    _removeFromScreen(item.slug);
  }

  /// Hides [item] for [days] days ("later").
  Future<void> snooze(Announcement item, int days) async {
    await _store.snooze(item.slug, DateTime.now().add(Duration(days: days)));
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
  void report(
    AnnouncementEvent event,
    Announcement item,
    int position, {
    ClickTarget? target,
    String? station,
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
    });
    if (_queue.length >= _maxQueuedEvents) _queue.removeAt(0);
    _queue.add({
      'slug': item.slug,
      'type': event.apiName,
      'position': position,
      'target': target?.name,
      'placement': item.placement.name,
      'station_slug': stationSlug,
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
        _backgroundedAt ??= DateTime.now();
        unawaited(flush());
      case AppLifecycleState.resumed:
        final away = _backgroundedAt;
        _backgroundedAt = null;
        if (away == null) return;
        final stale = DateTime.now().difference(away) > _staleAfter;
        unawaited(refresh(showChanges: stale));
      default:
        break;
    }
  }

  /// Stops listening to the app's lifecycle (a test's simulated restart).
  void dispose() => WidgetsBinding.instance.removeObserver(this);
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
