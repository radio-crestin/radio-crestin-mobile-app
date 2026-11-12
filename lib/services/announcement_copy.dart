import '../utils/romanian_months.dart';

/// The announcement UI's own words. The announcements themselves come
/// from the API; these frame them.
class AnnouncementCopy {
  AnnouncementCopy._();

  static const close = 'Închide';
  static const back = 'Înapoi';
  static const carouselLabel = 'Anunțuri';
  static const linkFailed = 'Nu s-a putut deschide linkul';
  static const linkFailedHint = 'Încearcă din nou mai târziu.';

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
