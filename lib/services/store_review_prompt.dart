/// How the app asks for a store rating once the listener has used it a
/// while (see `Utils.reviewDialogThresholds`).
enum StoreReviewPrompt {
  /// The app's "Lasă-ne un review de 5 stele" dialog, whose "5 stele"
  /// opens the store's review sheet: iPhone, iPad and Android phones.
  dialog,

  /// The system's rating prompt alone (`SKStoreReviewController`): macOS.
  ///
  /// A modal dialog of the app's own would interrupt a desktop app, and
  /// App Review wants the system prompt there. macOS decides whether it
  /// shows, at most three times a year, and never in a TestFlight build.
  system,

  /// None: Android TV, Windows and Linux have no in-app review, and their
  /// apps are not in the stores the prompts open.
  none;

  /// The prompt for a device: an Android TV ([androidTv]), a [desktop]
  /// computer, which may be a Mac ([macOS]), or else a phone or tablet.
  static StoreReviewPrompt resolve({
    required bool androidTv,
    required bool desktop,
    required bool macOS,
  }) {
    if (androidTv) return none;
    if (desktop) return macOS ? system : none;
    return dialog;
  }
}
