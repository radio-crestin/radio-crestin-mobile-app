import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// A version of the app the Mac App Store has.
@immutable
class MacAppStoreRelease {
  const MacAppStoreRelease({required this.version, this.releaseNotes = ''});

  /// As the store shows it, e.g. "1.6.0".
  final String version;

  /// "Ce e nou" for the version, as written for the store; may be empty.
  final String releaseNotes;
}

/// Finds out whether the Mac App Store has a newer version of the app than
/// the one running, for the desktop shell to offer it.
///
/// The store's lookup service names the app's listing by its bundle id.
/// Only a Mac release (`kind` "mac-software") counts: the iPhone app shares
/// the listing, and its version can come out before the Mac one does, so
/// a Mac is never told to update to a version it can't install. A listener
/// who puts an update off with "Mai târziu" isn't asked about that version
/// again for [snooze].
class MacAppStoreUpdates {
  MacAppStoreUpdates({
    required SharedPreferences prefs,
    required String currentVersion,
    http.Client? client,
    DateTime Function()? now,
  })  : _prefs = prefs,
        _currentVersion = currentVersion,
        _client = client,
        _now = now ?? DateTime.now;

  static const String bundleId = 'com.radiocrestinsoftware.radioApp';

  /// How long "Mai târziu" keeps a version from being offered again.
  static const Duration snooze = Duration(days: 3);

  static const Duration _timeout = Duration(seconds: 10);

  static const String _postponedVersionKey = 'mac_update_postponed_version';
  static const String _postponedAtKey = 'mac_update_postponed_at';

  /// A version to offer as if the store had it, for trying the dialog out:
  /// `flutter run -d macos --dart-define=RC_MAC_UPDATE_PREVIEW=1.6.0`.
  static const String previewVersion =
      String.fromEnvironment('RC_MAC_UPDATE_PREVIEW');

  static final Uri lookupUri = Uri.https('itunes.apple.com', '/lookup', {
    'bundleId': bundleId,
    'country': 'ro',
    'entity': 'macSoftware',
  });

  final SharedPreferences _prefs;
  final String _currentVersion;
  final http.Client? _client;
  final DateTime Function() _now;

  /// The Mac release in a lookup's response [body], or null when it has
  /// none: no result, only the iPhone app, or not the store's format.
  static MacAppStoreRelease? parseLookup(String body) {
    try {
      final results = (json.decode(body) as Map)['results'];
      if (results is! List) return null;
      for (final result in results) {
        if (result is! Map || result['kind'] != 'mac-software') continue;
        final version = result['version'];
        if (version is! String || version.isEmpty) continue;
        final notes = result['releaseNotes'];
        return MacAppStoreRelease(
          version: version,
          releaseNotes: notes is String ? notes.trim() : '',
        );
      }
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
    return null;
  }

  /// Whether version [candidate] comes after [current], part by part as
  /// numbers ("1.10.0" after "1.9.2"); a missing part counts as 0.
  static bool isNewer(String candidate, String current) {
    List<int> parts(String version) => [
          for (final part in version.split('+').first.split('.'))
            int.tryParse(part.trim()) ?? 0,
        ];
    final a = parts(candidate);
    final b = parts(current);
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// The release to offer now, or null: none newer than this version, the
  /// store unreachable, or the newer one put off lately.
  Future<MacAppStoreRelease?> check() async {
    final release = previewVersion.isNotEmpty
        ? const MacAppStoreRelease(
            version: previewVersion,
            releaseNotes: 'Previzualizare: așa arată fereastra când Mac App '
                'Store are o versiune nouă.\n\n• Pornire mai rapidă\n'
                '• Categoriile se pot trage cu mouse-ul\n'
                '• Ascultate recent în meniul din Dock',
          )
        : await _fetch();
    if (release == null || !isNewer(release.version, _currentVersion)) {
      return null;
    }
    if (_isPostponed(release.version)) return null;
    return release;
  }

  /// Keeps [release] from being offered again for [snooze].
  Future<void> postpone(MacAppStoreRelease release) async {
    await _prefs.setString(_postponedVersionKey, release.version);
    await _prefs.setInt(
        _postponedAtKey, _now().millisecondsSinceEpoch);
  }

  bool _isPostponed(String version) {
    if (_prefs.getString(_postponedVersionKey) != version) return false;
    final at = _prefs.getInt(_postponedAtKey);
    if (at == null) return false;
    final since =
        _now().difference(DateTime.fromMillisecondsSinceEpoch(at));
    return since < snooze;
  }

  Future<MacAppStoreRelease?> _fetch() async {
    final client = _client ?? http.Client();
    try {
      final response = await client.get(lookupUri).timeout(_timeout);
      if (response.statusCode != 200) return null;
      return parseLookup(utf8.decode(response.bodyBytes));
    } catch (e) {
      developer.log('MacAppStoreUpdates: lookup failed: $e');
      return null;
    } finally {
      if (_client == null) client.close();
    }
  }
}
