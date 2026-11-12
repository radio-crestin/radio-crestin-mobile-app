/// Announcements as `GET /announcements/` lists them (the announcements
/// spec), for the fake server to serve.
class AnnouncementFixtures {
  AnnouncementFixtures._();

  static const verseSlug = 'e2e-verse';
  static const verseTitle = 'Daily verse on WhatsApp';
  static const concertSlug = 'e2e-concert';
  static const concertTitle = 'Christmas concert, live';
  static const concertButton = 'See the program';
  static const pageTitle = 'The Christmas concert program';
  static const pageHeading = 'Program';
  static const stationNewsSlug = 'e2e-station-news';
  static const stationNewsTitle = 'Prayer hour tonight';
  static const formAnnouncementSlug = 'e2e-poll-announcement';
  static const formSlug = 'e2e-poll';
  static const formButton = 'Vote now';

  /// An announcement inside [station] only.
  static Map<String, Object?> stationNews(String station) => {
        ...concert(),
        'slug': stationNewsSlug,
        'title': stationNewsTitle,
        'placement': 'station',
        'station_slugs': [station],
        'secondary_button': null,
      };

  /// A poll: its button opens a form.
  static Map<String, Object?> poll() => {
        ...verse(),
        'slug': formAnnouncementSlug,
        'title': 'Which station do you listen to in the morning?',
        'button': _button(formButton, '#2563EB', {
          'type': 'form',
          'form_slug': formSlug,
        }),
      };

  /// A WhatsApp invitation with an external link.
  static Map<String, Object?> verse() => {
        'slug': verseSlug,
        'priority': 10,
        'category': _category('community', 'Community', '#0F6E63'),
        'icon': {'name': 'whatsapp', 'url': null},
        'title': verseTitle,
        'body_markdown': 'A verse **every day at 7:30**, on your phone.',
        'button': _button('Join the group', '#0F6E63', {
          'type': 'external',
          'url': 'https://example.com/whatsapp',
        }),
        'secondary_button': null,
        'page': null,
        'dismissible': true,
        'starts_at': '2026-11-12T00:00:00Z',
        'ends_at': null,
        'hide_after_seconds': null,
        'max_impressions': null,
        'placement': 'home',
        'station_slugs': <String>[],
        'filters': {
          'platforms': ['android', 'ios'],
          'countries_include': <String>[],
          'countries_exclude': <String>[],
          'locales': <String>[],
          'min_app_version': '1.0.0',
          'max_app_version': null,
        },
      };

  /// An event whose button opens its own page.
  static Map<String, Object?> concert() => {
        'slug': concertSlug,
        'priority': 5,
        'category': _category('event', 'Event', '#7C3AED'),
        'icon': {'name': 'calendar', 'url': null},
        'title': concertTitle,
        'body_markdown': 'Listen *live* on **Radio Alpha** at 19:00.',
        'button': {
          ..._button(concertButton, '#7C3AED', {'type': 'page'}),
          'style': 'text',
        },
        'secondary_button': {
          'label': 'Later',
          'kind': 'later',
          'later_days': 3,
          'action': null,
        },
        'page': {
          'title': pageTitle,
          'cover_image_url': null,
          'markdown': '''
On **December 20th at 19:00**, live.

## $pageHeading

- 19:00 Opening
- 19:15 Carols

> For unto you is born this day a Saviour.

[More](https://example.com/concert)
''',
        },
        'dismissible': true,
        'starts_at': '2026-11-12T00:00:00Z',
        'ends_at': null,
        'hide_after_seconds': null,
        'max_impressions': null,
        'placement': 'home',
        'station_slugs': <String>[],
        'filters': <String, Object?>{},
      };

  /// Shown only where the country is known to be [country].
  static Map<String, Object?> onlyIn(
          Map<String, Object?> item, String country) =>
      {
        ...item,
        'filters': {
          'countries_include': [country],
        },
      };

  static Map<String, Object?> _category(String slug, String name, String hex) =>
      {'slug': slug, 'name': name, 'color': hex, 'text_color': '#FFFFFF'};

  static Map<String, Object?> _button(
    String label,
    String hex,
    Map<String, Object?> action,
  ) =>
      {
        'label': label,
        'style': 'filled',
        'color': hex,
        'text_color': '#FFFFFF',
        'icon': 'auto',
        'action': {
          'url': null,
          'web_target': 'new_tab',
          'android_intent_uri': null,
          'fallback_url': null,
          'station_slug': null,
          ...action,
        },
      };
}
