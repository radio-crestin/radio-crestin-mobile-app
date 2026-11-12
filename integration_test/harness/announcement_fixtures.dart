/// Announcements as `GET /announcements/<slug>/` sends them (the
/// announcements spec, backend `announcement_feed.serialize`): absent
/// values are left out, `filters` keeps its nulls. The fake server drops
/// the page's markdown from the list, as the API does.
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
  static const webOnlySlug = 'e2e-web-only';
  static const webOnlyTitle = 'Only on the website';

  /// A WhatsApp invitation with an external link, for phones and tablets
  /// from 1.0.0.
  static Map<String, Object?> verse() => {
        'slug': verseSlug,
        'priority': 10,
        'placement': 'home',
        'station_slugs': <String>[],
        'category': _category('community', 'Community', '#0F6E63'),
        'icon': {'name': 'whatsapp'},
        'title': verseTitle,
        'body_markdown': 'A verse **every day at 7:30**, on your phone.',
        'button': _button('Join the group', '#0F6E63', {
          'type': 'external',
          'url': 'https://example.com/whatsapp',
          'web_target': 'new_tab',
        }),
        'dismissible': true,
        'starts_at': '2026-11-12T00:00:00Z',
        'filters': _filters(
          platforms: ['android', 'ios'],
          minAppVersion: '1.0.0',
        ),
      };

  /// An event whose button (a text link) opens its own page, with a
  /// "later" second button.
  static Map<String, Object?> concert() => {
        'slug': concertSlug,
        'priority': 5,
        'placement': 'home',
        'station_slugs': <String>[],
        'category': _category('event', 'Event', '#7C3AED'),
        'icon': {'name': 'calendar'},
        'title': concertTitle,
        'body_markdown': 'Listen *live* on **Radio Alpha** at 19:00.',
        'button': {
          ..._button(concertButton, '#7C3AED', {'type': 'page'}),
          'style': 'text',
        },
        'page': {
          'title': pageTitle,
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
        'filters': _filters(),
      };

  /// An announcement inside [station] only.
  static Map<String, Object?> stationNews(String station) => {
        ...concert(),
        'slug': stationNewsSlug,
        'title': stationNewsTitle,
        'placement': 'station',
        'station_slugs': [station],
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

  static const longPrimary = 'Answer the four short questions';
  static const legacySecondary = 'Remind me in a few days';

  /// A long main button, and the second button an older list kept on the
  /// device may still carry: the app ignores it.
  static Map<String, Object?> longButtons() => {
        ...verse(),
        'slug': 'e2e-long-buttons',
        'title': 'Tell us what you think',
        'button': _button(longPrimary, '#4F46E5', {
          'type': 'external',
          'url': 'https://example.com/survey',
        }),
        'secondary_button': {
          'label': legacySecondary,
          'kind': 'later',
          'later_days': 3,
        },
      };

  static const videoSlug = 'e2e-videos';
  static const videoTitle = 'Watch the concert';
  static const videoPageTitle = 'Videos from the concert';

  /// A page with a YouTube video (with a start time), a Short and a
  /// playlist, each a paragraph of its own, and a YouTube link inside a
  /// sentence, which stays a link.
  static Map<String, Object?> videos() => {
        ...concert(),
        'slug': videoSlug,
        'title': videoTitle,
        'page': {
          'title': videoPageTitle,
          'markdown': '''
The concert, from the start:

https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m5s

A short moment:

<https://youtube.com/shorts/aqz-KE-bpKQ>

[https://www.youtube.com/playlist?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI](https://www.youtube.com/playlist?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI)

Or open it [on YouTube](https://www.youtube.com/watch?v=dQw4w9WgXcQ) yourself.
''',
        },
      };

  static const uncoloredTitle = 'Colors from the app';
  static const uncoloredCategory = 'News';
  static const uncoloredButton = 'Read on';

  /// No colors at all, as the API sends one the admin left on the
  /// default: the app colors it from its theme.
  static Map<String, Object?> uncolored() => {
        ...verse(),
        'slug': 'e2e-uncolored',
        'title': uncoloredTitle,
        'category': {'slug': 'news', 'name': uncoloredCategory},
        'button': {
          'label': uncoloredButton,
          'style': 'filled',
          'icon': 'auto',
          'action': {'type': 'external', 'url': 'https://example.com/news'},
        },
      };

  /// For the website only: a phone never shows it.
  static Map<String, Object?> webOnly() => {
        ...verse(),
        'slug': webOnlySlug,
        'title': webOnlyTitle,
        'priority': 20,
        'filters': _filters(platforms: ['web_mobile', 'web_desktop']),
      };

  static Map<String, Object?> _filters({
    List<String> platforms = const [],
    String? minAppVersion,
  }) =>
      {
        'platforms': platforms,
        'countries_include': <String>[],
        'countries_exclude': <String>[],
        'locales': <String>[],
        'min_app_version': minAppVersion,
        'max_app_version': null,
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
        'action': action,
      };
}
