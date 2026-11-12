import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What this device remembers about announcements, in the
/// SharedPreferences keys the announcements spec names: which were closed,
/// which wait until later, how often each was seen, and where rotation is.
class AnnouncementStore {
  AnnouncementStore(this._prefs);

  static const dismissedKey = 'announcements_dismissed';
  static const snoozedKey = 'announcements_snoozed';
  static const impressionsKey = 'announcements_impressions';
  static const rotationCursorKey = 'announcements_rotation_cursor';

  final SharedPreferences _prefs;

  /// The slugs closed for good on this device.
  Set<String> get dismissed =>
      (_prefs.getStringList(dismissedKey) ?? const []).toSet();

  Future<void> dismiss(String slug) async {
    final slugs = dismissed..add(slug);
    await _prefs.setStringList(dismissedKey, slugs.toList());
  }

  /// Whether [slug] waits until later at [now].
  bool isSnoozed(String slug, DateTime now) {
    final until = DateTime.tryParse('${_snoozed[slug] ?? ''}');
    return until != null && until.isAfter(now);
  }

  /// Hides [slug] until [until].
  Future<void> snooze(String slug, DateTime until) async {
    final snoozed = _snoozed
      ..removeWhere((_, value) => !_isFuture(value))
      ..[slug] = until.toUtc().toIso8601String();
    await _prefs.setString(snoozedKey, jsonEncode(snoozed));
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

  Map<String, Object?> get _snoozed => _readMap(snoozedKey);

  Map<String, Object?> get _impressions => _readMap(impressionsKey);

  Map<String, Object?> _readMap(String key) {
    try {
      final decoded = jsonDecode(_prefs.getString(key) ?? '{}');
      return decoded is Map ? decoded.cast<String, Object?>() : {};
    } on FormatException {
      return {};
    }
  }

  static bool _isFuture(Object? iso) {
    final at = DateTime.tryParse('${iso ?? ''}');
    return at != null && at.isAfter(DateTime.now());
  }
}
