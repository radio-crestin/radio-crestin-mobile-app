import 'dart:ui' show Color;

/// What tapping an announcement's button does (`action.type` in the API).
enum AnnouncementActionType {
  external,
  inAppBrowser,
  androidIntent,
  page,
  station,
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

/// A button's action: open a link, an app, a page or a station.
class AnnouncementAction {
  const AnnouncementAction({
    required this.type,
    this.url,
    this.androidIntentUri,
    this.fallbackUrl,
    this.stationSlug,
  });

  final AnnouncementActionType type;
  final String? url;
  final String? androidIntentUri;
  final String? fallbackUrl;
  final String? stationSlug;

  static AnnouncementAction? fromJson(Object? json) {
    if (json is! Map) return null;
    return AnnouncementAction(
      type: AnnouncementActionType.parse(json['type']),
      url: _string(json['url']),
      androidIntentUri: _string(json['android_intent_uri']),
      fallbackUrl: _string(json['fallback_url']),
      stationSlug: _string(json['station_slug']),
    );
  }
}

/// The look of the primary button.
enum AnnouncementButtonStyle { filled, outline, text }

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
  final Color textColor;

  /// `auto` (from the action), `none`, or an icon name.
  final String icon;
  final AnnouncementAction action;

  static AnnouncementButton? fromJson(Object? json, Color fallbackColor) {
    if (json is! Map) return null;
    final action = AnnouncementAction.fromJson(json['action']);
    final label = _string(json['label']);
    if (label == null || action == null) return null;
    if (action.type == AnnouncementActionType.none) return null;
    final color = parseHexColor(json['color']) ?? fallbackColor;
    return AnnouncementButton(
      label: label,
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

/// What the second button does besides being tapped.
enum SecondaryButtonKind { close, later, action }

/// The second, quieter button: close for good, later, or an action.
class AnnouncementSecondaryButton {
  const AnnouncementSecondaryButton({
    required this.label,
    required this.kind,
    this.laterDays,
    this.action,
  });

  final String label;
  final SecondaryButtonKind kind;

  /// For [SecondaryButtonKind.later]: how many days to hide it.
  final int? laterDays;

  /// For [SecondaryButtonKind.action].
  final AnnouncementAction? action;

  static AnnouncementSecondaryButton? fromJson(Object? json) {
    if (json is! Map) return null;
    final label = _string(json['label']);
    final kind = SecondaryButtonKind.values
        .where((kind) => kind.name == json['kind'])
        .firstOrNull;
    if (label == null || kind == null) return null;
    final action = AnnouncementAction.fromJson(json['action']);
    if (kind == SecondaryButtonKind.action && action == null) return null;
    return AnnouncementSecondaryButton(
      label: label,
      kind: kind,
      laterDays: (json['later_days'] as num?)?.toInt(),
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

/// The full-screen page an announcement can open.
class AnnouncementPageContent {
  const AnnouncementPageContent({
    required this.title,
    required this.markdown,
    this.coverImageUrl,
  });

  final String title;
  final String markdown;
  final String? coverImageUrl;

  static AnnouncementPageContent? fromJson(Object? json, String fallbackTitle) {
    if (json is! Map) return null;
    return AnnouncementPageContent(
      title: _string(json['title']) ?? fallbackTitle,
      markdown: _string(json['markdown']) ?? '',
      coverImageUrl: _string(json['cover_image_url']),
    );
  }
}

/// One announcement, as `GET /announcements/` lists it.
class Announcement {
  const Announcement({
    required this.slug,
    required this.category,
    required this.title,
    required this.bodyMarkdown,
    required this.dismissible,
    this.iconName,
    this.iconUrl,
    this.button,
    this.secondaryButton,
    this.page,
    this.startsAt,
    this.endsAt,
    this.hideAfterSeconds,
    this.maxImpressions,
  });

  final String slug;
  final AnnouncementCategory category;
  final String? iconName;
  final String? iconUrl;
  final String title;
  final String bodyMarkdown;
  final AnnouncementButton? button;
  final AnnouncementSecondaryButton? secondaryButton;
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
      iconName: _string(icon['name']),
      iconUrl: _string(icon['url']),
      title: title,
      bodyMarkdown: _string(json['body_markdown']) ?? '',
      button: AnnouncementButton.fromJson(json['button'], category.color),
      secondaryButton:
          AnnouncementSecondaryButton.fromJson(json['secondary_button']),
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
    this.autoplaySeconds = 8,
  });

  final RotationMode rotationMode;

  /// Seconds each card shows before the next one; 0 turns autoplay off.
  final int autoplaySeconds;

  static AnnouncementSettings fromJson(Object? json) {
    if (json is! Map) return const AnnouncementSettings();
    return AnnouncementSettings(
      rotationMode: RotationMode.values.firstWhere(
        (mode) => mode.name == json['rotation_mode'],
        orElse: () => RotationMode.fixed,
      ),
      autoplaySeconds: (json['autoplay_seconds'] as num?)?.toInt() ?? 8,
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
