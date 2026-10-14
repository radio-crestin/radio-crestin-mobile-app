/// What the CarPlay templates support on the running iOS version.
class CPCapabilities {
  const CPCapabilities({
    required this.supportsHeaderGridButtons,
    required this.maximumHeaderGridButtonCount,
    required this.supportsHeaderImageRow,
    required this.maximumHeaderImageRowCount,
  });

  /// Assumed when iOS can't be asked (another platform, a failed call):
  /// only what every supported iOS version has.
  static const fallback = CPCapabilities(
    supportsHeaderGridButtons: false,
    maximumHeaderGridButtonCount: 0,
    supportsHeaderImageRow: false,
    maximumHeaderImageRowCount: 0,
  );

  /// Whether lists can pin grid buttons above their sections (iOS 26+).
  final bool supportsHeaderGridButtons;

  /// How many pinned buttons a list shows; extra ones are left out.
  final int maximumHeaderGridButtonCount;

  /// Whether lists can show a titled row of pictures above their sections
  /// (iOS 26+), see `CPListTemplate.headerImageRow`.
  final bool supportsHeaderImageRow;

  /// How many pictures that row takes; extra ones are left out.
  final int maximumHeaderImageRowCount;

  factory CPCapabilities.fromJson(Map<dynamic, dynamic> json) =>
      CPCapabilities(
        supportsHeaderGridButtons:
            json['supportsHeaderGridButtons'] as bool? ?? false,
        maximumHeaderGridButtonCount:
            json['maximumHeaderGridButtonCount'] as int? ?? 0,
        supportsHeaderImageRow:
            json['supportsHeaderImageRow'] as bool? ?? false,
        maximumHeaderImageRowCount:
            json['maximumHeaderImageRowCount'] as int? ?? 0,
      );
}
