import '../utils/romanian_months.dart';

/// The announcement UI's own words. The announcements themselves come
/// from the API; these frame them.
class AnnouncementCopy {
  AnnouncementCopy._();

  static const close = 'Închide';
  static const back = 'Înapoi';
  static const carouselLabel = 'Anunțuri';

  /// The buttons that move the home card between announcements (the
  /// design's copy, made with Codex).
  static const previous = 'Anunțul anterior';
  static const next = 'Anunțul următor';
  static const linkFailed = 'Nu s-a putut deschide linkul';
  static const linkFailedHint = 'Încearcă din nou mai târziu.';

  /// The button that hides an announcement for good, and what a screen
  /// reader says for it.
  static const dismiss = 'Ascunde';
  static const dismissLabel = 'Ascunde acest anunț';

  /// A video's thumbnail in an announcement's page: what a tap does, read
  /// out when the backend has no title for it (made with Codex).
  static const playVideo = 'Redă videoclipul';
  static const playShort = 'Redă clipul scurt';
  static const playPlaylist = 'Redă lista de redare';

  /// The station announcements' sheet and bells.
  static const stationSheetTitle = 'Anunțuri ale postului';
  static String stationSheetSubtitle(String station) => 'De la $station';
  static const bellLabel = 'Anunțuri pentru acest post';

  /// "1 din 3" above the title when there are several.
  static String count(int index, int count) => '$index din $count';

  /// What a screen reader says for one card of several.
  static String slideLabel(int index, int count) => 'Anunțul $index din $count';

  /// The date under a page's title.
  static String publishedOn(DateTime date) {
    final local = date.toLocal();
    final month = romanianMonths[local.month - 1];
    return 'Publicat la ${local.day} $month ${local.year}';
  }
}
