import 'dart:ui' show Color;

/// What tapping an announcement's button does (`action.type` in the API).
enum AnnouncementActionType {
  external,
  inAppBrowser,
  androidIntent,
  page,
  station,
  form,
  none;

  /// The API's name for this type, also sent to PostHog as `action_type`.
  String get apiName => switch (this) {
        inAppBrowser => 'in_app_browser',
        androidIntent => 'android_intent',
        _ => name,
      };

  static AnnouncementActionType parse(Object? value) =>
      values.firstWhere((type) => type.apiName == value, orElse: () => none);
}

/// A button's action: open a link, an app, a page, a station or a form.
class AnnouncementAction {
  const AnnouncementAction({
    required this.type,
    this.url,
    this.androidIntentUri,
    this.fallbackUrl,
    this.stationSlug,
    this.formSlug,
  });

  final AnnouncementActionType type;
  final String? url;
  final String? androidIntentUri;
  final String? fallbackUrl;
  final String? stationSlug;
  final String? formSlug;

  static AnnouncementAction? fromJson(Object? json) {
    if (json is! Map) return null;
    return AnnouncementAction(
      type: AnnouncementActionType.parse(json['type']),
      url: _string(json['url']),
      androidIntentUri: _string(json['android_intent_uri']),
      fallbackUrl: _string(json['fallback_url']),
      stationSlug: _string(json['station_slug']),
      formSlug: _string(json['form_slug']),
    );
  }
}

/// The look of the primary button; [hidden] draws none, but the card
/// still runs its action when tapped.
enum AnnouncementButtonStyle { filled, outline, text, hidden }

/// The primary button: a label, a look and an action.
class AnnouncementButton {
  const AnnouncementButton({
    required this.label,
    required this.style,
    required this.color,
    required this.textColor,
    required this.icon,
    required this.action,
  });

  final String label;
  final AnnouncementButtonStyle style;
  final Color color;

  /// The label's color, as the admin set it (or the server's contrast
  /// pick); computed here only when the API sends none.
  final Color textColor;

  /// `auto` (from the action), `none`, or an icon name.
  final String icon;
  final AnnouncementAction action;

  bool get isVisible => style != AnnouncementButtonStyle.hidden;

  static AnnouncementButton? fromJson(Object? json, Color fallbackColor) {
    if (json is! Map) return null;
    final action = AnnouncementAction.fromJson(json['action']);
    if (action == null || action.type == AnnouncementActionType.none) {
      return null;
    }
    final color = parseHexColor(json['color']) ?? fallbackColor;
    return AnnouncementButton(
      label: _string(json['label']) ?? '',
      style: AnnouncementButtonStyle.values.firstWhere(
        (style) => style.name == json['style'],
        orElse: () => AnnouncementButtonStyle.filled,
      ),
      color: color,
      textColor: parseHexColor(json['text_color']) ?? readableOn(color),
      icon: _string(json['icon']) ?? 'auto',
      action: action,
    );
  }
}

/// The category tag: a name on a colored pill.
class AnnouncementCategory {
  const AnnouncementCategory({
    required this.slug,
    required this.name,
    required this.color,
    required this.textColor,
  });

  final String slug;
  final String name;
  final Color color;
  final Color textColor;

  static const _fallbackColor = Color(0xFF0F6E63);

  static AnnouncementCategory fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final color = parseHexColor(map['color']) ?? _fallbackColor;
    return AnnouncementCategory(
      slug: _string(map['slug']) ?? '',
      name: _string(map['name']) ?? '',
      color: color,
      textColor: parseHexColor(map['text_color']) ?? readableOn(color),
    );
  }
}

/// The full-screen page an announcement can open. The list sends only its
/// title and cover; the markdown comes with the single announcement.
class AnnouncementPageContent {
  const AnnouncementPageContent({
    required this.title,
    this.markdown,
    this.coverImageUrl,
  });

  final String title;
  final String? markdown;
  final String? coverImageUrl;

  static AnnouncementPageContent? fromJson(Object? json, String fallbackTitle) {
    if (json is! Map) return null;
    return AnnouncementPageContent(
      title: _string(json['title']) ?? fallbackTitle,
      markdown: _string(json['markdown']),
      coverImageUrl: _string(json['cover_image_url']),
    );
  }
}

/// Where an announcement shows: the home card, or inside the stations it
/// names.
enum AnnouncementPlacement { home, station }

/// Who an announcement is for, checked on the device (the list is the same
/// for everyone, so Cloudflare can cache it). Empty lists match everyone.
class AnnouncementFilters {
  const AnnouncementFilters({
    this.platforms = const [],
    this.countriesInclude = const [],
    this.countriesExclude = const [],
    this.locales = const [],
    this.minAppVersion,
    this.maxAppVersion,
  });

  final List<String> platforms;
  final List<String> countriesInclude;
  final List<String> countriesExclude;
  final List<String> locales;
  final String? minAppVersion;
  final String? maxAppVersion;

  static AnnouncementFilters fromJson(Object? json) {
    if (json is! Map) return const AnnouncementFilters();
    List<String> list(String key) => [
          for (final value in json[key] as List? ?? const [])
            if (value is String && value.isNotEmpty) value,
        ];
    return AnnouncementFilters(
      platforms: list('platforms'),
      countriesInclude: list('countries_include'),
      countriesExclude: list('countries_exclude'),
      locales: list('locales'),
      minAppVersion: _string(json['min_app_version']),
      maxAppVersion: _string(json['max_app_version']),
    );
  }

  /// Whether a device on [platform] (`android`/`ios`), with [locale] (a
  /// tag like `ro-RO`), [appVersion] and [country] (ISO-2, or null when
  /// not known yet) is meant to see it.
  bool matches({
    required String platform,
    required String locale,
    required String appVersion,
    required String? country,
  }) =>
      (platforms.isEmpty || platforms.contains(platform)) &&
      (locales.isEmpty ||
          locales.any((wanted) => _localeMatches(wanted, locale))) &&
      _versionInRange(appVersion) &&
      _countryMatches(country);

  /// A country rule hides it while the country is unknown.
  bool _countryMatches(String? country) {
    if (countriesInclude.isEmpty && countriesExclude.isEmpty) return true;
    if (country == null) return false;
    final code = country.toUpperCase();
    bool has(List<String> codes) =>
        codes.any((value) => value.toUpperCase() == code);
    return (countriesInclude.isEmpty || has(countriesInclude)) &&
        !has(countriesExclude);
  }

  bool _versionInRange(String appVersion) {
    final min = minAppVersion, max = maxAppVersion;
    if (min != null && compareVersions(appVersion, min) < 0) return false;
    if (max != null && compareVersions(appVersion, max) > 0) return false;
    return true;
  }

  /// `ro` matches `ro-RO` and `ro_RO`; `ro-RO` matches only itself.
  static bool _localeMatches(String wanted, String locale) {
    String normal(String tag) => tag.replaceAll('_', '-').toLowerCase();
    final want = normal(wanted), have = normal(locale);
    return have == want || have.startsWith('$want-');
  }
}

/// Compares dotted versions number by number (`1.10.0` > `1.9.2`); a
/// missing part counts as 0 and anything after `+` or `-` is ignored.
int compareVersions(String a, String b) {
  List<int> parts(String version) => version
      .split(RegExp(r'[+-]'))
      .first
      .split('.')
      .map((part) => int.tryParse(part.trim()) ?? 0)
      .toList();
  final left = parts(a), right = parts(b);
  for (var i = 0; i < left.length || i < right.length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// One announcement, as `GET /announcements/` lists it.
class Announcement {
  const Announcement({
    required this.slug,
    required this.category,
    required this.title,
    required this.bodyMarkdown,
    required this.dismissible,
    this.placement = AnnouncementPlacement.home,
    this.stationSlugs = const [],
    this.filters = const AnnouncementFilters(),
    this.iconName,
    this.iconUrl,
    this.button,
    this.page,
    this.startsAt,
    this.endsAt,
    this.hideAfterSeconds,
    this.maxImpressions,
  });

  final String slug;
  final AnnouncementCategory category;
  final AnnouncementPlacement placement;

  /// For [AnnouncementPlacement.station]: the stations it shows inside.
  final List<String> stationSlugs;
  final AnnouncementFilters filters;
  final String? iconName;
  final String? iconUrl;
  final String title;
  final String bodyMarkdown;
  final AnnouncementButton? button;
  final AnnouncementPageContent? page;
  final bool dismissible;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final int? hideAfterSeconds;
  final int? maxImpressions;

  /// The card's accent: the button's color, else the category's.
  Color get color => button?.color ?? category.color;

  /// The type of the primary button's action, for analytics.
  String get actionType =>
      (button?.action.type ?? AnnouncementActionType.none).apiName;

  /// Whether it shows between its start and end at [now].
  bool isLiveAt(DateTime now) =>
      (startsAt == null || !startsAt!.isAfter(now)) &&
      (endsAt == null || endsAt!.isAfter(now));

  /// What decides the card's height: the same signature means an update
  /// can apply while the card is on screen without moving anything.
  String get layoutSignature => [
        title,
        bodyMarkdown,
        category.name,
        iconUrl != null,
        button?.isVisible == true ? button!.label : '',
        button?.style.name,
        dismissible,
      ].join('\u0000');

  /// Parses one item, or null when it lacks a slug or a title.
  static Announcement? fromJson(Object? json) {
    if (json is! Map) return null;
    final slug = _string(json['slug']);
    final title = _string(json['title']);
    if (slug == null || title == null) return null;
    final category = AnnouncementCategory.fromJson(json['category']);
    final icon = json['icon'] is Map ? json['icon'] as Map : const {};
    return Announcement(
      slug: slug,
      category: category,
      placement: json['placement'] == 'station'
          ? AnnouncementPlacement.station
          : AnnouncementPlacement.home,
      stationSlugs: [
        for (final value in json['station_slugs'] as List? ?? const [])
          if (value is String) value,
      ],
      filters: AnnouncementFilters.fromJson(json['filters']),
      iconName: _string(icon['name']),
      iconUrl: _string(icon['url']),
      title: title,
      bodyMarkdown: _string(json['body_markdown']) ?? '',
      // A list kept from before still has `secondary_button`: the second
      // button is gone, so it is ignored.
      button: AnnouncementButton.fromJson(json['button'], category.color),
      page: AnnouncementPageContent.fromJson(json['page'], title),
      dismissible: json['dismissible'] != false,
      startsAt: DateTime.tryParse(_string(json['starts_at']) ?? ''),
      endsAt: DateTime.tryParse(_string(json['ends_at']) ?? ''),
      hideAfterSeconds: (json['hide_after_seconds'] as num?)?.toInt(),
      maxImpressions: (json['max_impressions'] as num?)?.toInt(),
    );
  }
}

/// How the first announcement is chosen (`settings.rotation_mode`).
enum RotationMode { fixed, rotate, random }

/// The list's settings, sent with every list.
class AnnouncementSettings {
  const AnnouncementSettings({
    this.rotationMode = RotationMode.fixed,
    this.maxPerLoad,
  });

  final RotationMode rotationMode;

  /// How many home announcements show at most, counted after the device
  /// dropped those not meant for it; null shows them all.
  final int? maxPerLoad;

  static AnnouncementSettings fromJson(Object? json) {
    if (json is! Map) return const AnnouncementSettings();
    final max = (json['max_per_load'] as num?)?.toInt();
    return AnnouncementSettings(
      rotationMode: RotationMode.values.firstWhere(
        (mode) => mode.name == json['rotation_mode'],
        orElse: () => RotationMode.fixed,
      ),
      maxPerLoad: max != null && max > 0 ? max : null,
    );
  }
}

String? _string(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

/// Parses `#RRGGBB` (or `#AARRGGBB`), or null.
Color? parseHexColor(Object? value) {
  if (value is! String) return null;
  final hex = value.replaceFirst('#', '');
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return null;
  return switch (hex.length) {
    6 => Color(0xFF000000 | parsed),
    8 => Color(parsed),
    _ => null,
  };
}

/// White or near-black, whichever reads better on [background], as the
/// design's `inkOn`.
Color readableOn(Color background) {
  final luminance = background.computeLuminance();
  final onWhite = 1.05 / (luminance + 0.05);
  final onBlack = (luminance + 0.05) / 0.05;
  return onWhite >= onBlack ? const Color(0xFFFFFFFF) : const Color(0xFF111111);
}
