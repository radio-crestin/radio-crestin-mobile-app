import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What this device remembers about announcements, in the
/// SharedPreferences keys the announcements spec names: which were closed,
/// how often each was seen, where rotation is,
/// which station announcements were opened, the device's country, a
/// preview token, and the last list with its ETag.
class AnnouncementStore {
  AnnouncementStore(this._prefs);

  static const dismissedKey = 'announcements_dismissed';
  static const impressionsKey = 'announcements_impressions';
  static const rotationCursorKey = 'announcements_rotation_cursor';
  static const seenKey = 'announcements_seen';
  static const countryKey = 'announcements_country';
  static const previewTokenKey = 'announcements_preview_token';
  static const feedKey = 'announcements_feed';
  static const feedEtagKey = 'announcements_feed_etag';

  final SharedPreferences _prefs;

  /// Keys of features that are gone: the "later" button's snoozes.
  static const _retiredKeys = ['announcements_snoozed'];

  /// Drops what removed features left on the device.
  Future<void> forgetRetired() async {
    for (final key in _retiredKeys) {
      if (_prefs.containsKey(key)) await _prefs.remove(key);
    }
  }

  /// The station announcements whose sheet was opened on this device.
  Set<String> get seen => (_prefs.getStringList(seenKey) ?? const []).toSet();

  Future<void> markSeen(Iterable<String> slugs) async {
    final all = seen..addAll(slugs);
    await _prefs.setStringList(seenKey, all.toList());
  }

  /// The device's country (ISO-2) as the API last saw it, or null.
  String? get country => _prefs.getString(countryKey);

  Future<void> saveCountry(String? country) async {
    if (country == null || country.isEmpty || country == this.country) return;
    await _prefs.setString(countryKey, country.toUpperCase());
  }

  /// The token of an admin's preview link, which shows unpublished
  /// announcements; null when not previewing.
  String? get previewToken => _prefs.getString(previewTokenKey);

  Future<void> savePreviewToken(String? token) => token == null || token.isEmpty
      ? _prefs.remove(previewTokenKey)
      : _prefs.setString(previewTokenKey, token);

  /// The last list the API sent (its JSON body), or null.
  String? get feed => _prefs.getString(feedKey);

  String? get feedEtag => _prefs.getString(feedEtagKey);

  Future<void> saveFeed(String body, String? etag) async {
    await _prefs.setString(feedKey, body);
    if (etag == null) {
      await _prefs.remove(feedEtagKey);
    } else {
      await _prefs.setString(feedEtagKey, etag);
    }
  }

  /// The slugs closed for good on this device.
  Set<String> get dismissed =>
      (_prefs.getStringList(dismissedKey) ?? const []).toSet();

  Future<void> dismiss(String slug) async {
    final slugs = dismissed..add(slug);
    await _prefs.setStringList(dismissedKey, slugs.toList());
  }

  /// How many times [slug] was seen on this device.
  int impressions(String slug) => (_impressions[slug] as num?)?.toInt() ?? 0;

  Future<void> countImpression(String slug) async {
    final counts = _impressions..[slug] = impressions(slug) + 1;
    await _prefs.setString(impressionsKey, jsonEncode(counts));
  }

  int get rotationCursor => _prefs.getInt(rotationCursorKey) ?? 0;

  Future<void> advanceRotationCursor() =>
      _prefs.setInt(rotationCursorKey, rotationCursor + 1);

  Map<String, Object?> get _impressions => _readMap(impressionsKey);

  Map<String, Object?> _readMap(String key) {
    try {
      final decoded = jsonDecode(_prefs.getString(key) ?? '{}');
      return decoded is Map ? decoded.cast<String, Object?>() : {};
    } on FormatException {
      return {};
    }
  }
}
