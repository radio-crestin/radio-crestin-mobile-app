import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

extension CustomThemeColors on ThemeData {
  Color get cardColorSelected => brightness == Brightness.light
      ? const Color(0xFFD9D9D9)
      : const Color(0xFF353535);

  /// The fine outline of the playing station's card, around
  /// [cardColorSelected].
  Color get cardBorderSelected => brightness == Brightness.light
      ? Colors.black.withValues(alpha: 0.1)
      : const Color(0xFF555555).withValues(alpha: 0.35);

  /// Secondary text, such as the artist under a song or an icon's label.
  Color get textSecondary => brightness == Brightness.light
      ? AppColors.lightTextSecondary
      : AppColors.darkTextSecondary;

  /// The status snackbar's colors (offline, back online, station error).
  StatusSnackbarColors get statusSnackbarColors =>
      brightness == Brightness.light
          ? StatusSnackbarColors.onLight
          : StatusSnackbarColors.onDark;

  /// The device sheet's colors (cast button: Chromecast, AirPlay, TV, car).
  DeviceSheetColors get deviceSheetColors => brightness == Brightness.light
      ? DeviceSheetColors.light
      : DeviceSheetColors.dark;
}

/// Colors of the device sheet, for one theme brightness.
@immutable
class DeviceSheetColors {
  /// Creates a palette; the app uses [light] and [dark].
  const DeviceSheetColors({
    required this.sheet,
    required this.handle,
    required this.card,
    required this.cardInner,
    required this.textSecondary,
    required this.label,
    required this.icon,
    required this.chevron,
    required this.accent,
    required this.tint,
    required this.beta,
    required this.pulse,
  });

  /// The light theme's sheet.
  static const light = DeviceSheetColors(
    sheet: AppColors.lightSurface,
    handle: AppColors.deviceHandle,
    card: AppColors.deviceCard,
    cardInner: AppColors.deviceCardInner,
    textSecondary: AppColors.deviceTextSecondary,
    label: AppColors.deviceLabel,
    icon: AppColors.deviceIcon,
    chevron: AppColors.deviceChevron,
    accent: AppColors.deviceAccentOnLight,
    tint: AppColors.deviceTint,
    beta: AppColors.deviceBeta,
    pulse: AppColors.primary,
  );

  /// The dark theme's sheet.
  static const dark = DeviceSheetColors(
    sheet: AppColors.darkSurface,
    handle: AppColors.deviceHandleDark,
    card: AppColors.deviceCardDark,
    cardInner: AppColors.deviceCardInnerDark,
    textSecondary: AppColors.deviceTextSecondaryDark,
    label: AppColors.deviceLabelDark,
    icon: AppColors.deviceIconDark,
    chevron: AppColors.deviceChevronDark,
    accent: AppColors.deviceAccent,
    tint: AppColors.deviceTintDark,
    beta: AppColors.deviceBetaDark,
    pulse: AppColors.sleepAccent,
  );

  /// The sheet's surface.
  final Color sheet;

  /// The drag handle.
  final Color handle;

  /// The Chromecast card.
  final Color card;

  /// The circles and pills on the card (a device's icon, "Conectează").
  final Color cardInner;

  /// Explanations under a title.
  final Color textSecondary;

  /// Section labels ("SAU", "GĂSITE ÎN WI-FI-UL TĂU").
  final Color label;

  /// Row icons.
  final Color icon;

  /// The chevron at the end of a row.
  final Color chevron;

  /// Pink text ("Conectează", "BETA").
  final Color accent;

  /// The circle behind the lock.
  final Color tint;

  /// The "BETA" pill.
  final Color beta;

  /// The rings around the searching icon, and the spinner.
  final Color pulse;
}

/// Colors of the status snackbar, for one theme brightness.
///
/// The snackbar is a Material 3 inverse surface: light in the dark theme and
/// dark in the light theme, so it stands out from the page it floats over.
@immutable
class StatusSnackbarColors {
  /// Creates a palette; the app uses [onDark] and [onLight].
  const StatusSnackbarColors({
    required this.background,
    required this.text,
    required this.textSecondary,
    required this.action,
    required this.success,
  });

  /// The dark theme's snackbar (a light surface).
  static const onDark = StatusSnackbarColors(
    background: AppColors.statusSnackbar,
    text: AppColors.statusSnackbarText,
    textSecondary: AppColors.statusSnackbarTextSecondary,
    action: AppColors.statusSnackbarAction,
    success: AppColors.statusSnackbarSuccess,
  );

  /// The light theme's snackbar (a dark surface).
  static const onLight = StatusSnackbarColors(
    background: AppColors.statusSnackbarOnLight,
    text: AppColors.statusSnackbarTextOnLight,
    textSecondary: AppColors.statusSnackbarTextSecondaryOnLight,
    action: AppColors.statusSnackbarActionOnLight,
    success: AppColors.statusSnackbarSuccessOnLight,
  );

  /// The surface.
  final Color background;

  /// Titles.
  final Color text;

  /// Explanations under a title, and the offline icon.
  final Color textSecondary;

  /// The text button ("Reîncearcă").
  final Color action;

  /// The back-online check mark.
  final Color success;
}

// App Colors
class AppColors {
  // Primary colors
  static const Color primary = Color(0xffe91e63);
  static const Color primaryLight = Color(0xfff8bbd0);
  static const Color primaryDark = Color(0xff8f0133);

  // The mini player bar, and the controls that pair with it (the playlist
  // play button, the sleep sheet's chosen time): a deep crimson in the dark
  // theme and the brand's burgundy in the light one, both calmer than the
  // bright brand pink.
  static const Color playerBar = Color(0xff75002c);
  static const Color playerBarLight = primaryDark;

  // Light theme colors
  static const Color lightBackground = Color(0xfffafafa);
  static const Color lightSurface = Colors.white;
  static const Color lightText = Color(0xff000000);
  static const Color lightTextSecondary = Color(0x8a000000);
  static const Color lightDivider = Color(0x1f000000);

  // Dark theme colors
  static const Color darkBackground = Color(0xff121212);
  static const Color darkSurface = Color(0xff1e1e1e);
  static const Color darkText = Colors.white;
  static const Color darkTextSecondary = Color(0xb3ffffff);
  static const Color darkDivider = Color(0x1fffffff);

  // The full player's panel, from the glow behind the artwork to the bottom
  // edge: a wine that deepens downward in the dark theme, a soft pink that
  // pales downward in the light one. Opaque, so the station list never shows
  // through.
  static const List<Color> darkPlayerBackdrop = [
    Color(0xff4a1a2c),
    Color(0xff2b1019),
    Color(0xff170b10),
  ];
  static const List<Color> lightPlayerBackdrop = [
    Color(0xfffce4ec),
    Color(0xfff9e7ed),
    Color(0xfffaf1f4),
  ];

  // Sleep timer ("somn") ring and countdown: the brand pink, lightened on
  // dark surfaces and deepened on light ones so the small label keeps 4.5:1
  // contrast (plain `primary` falls just short on both).
  static const Color sleepAccent = Color(0xfff06292);
  static const Color sleepAccentOnLight = Color(0xffd81b60);

  // Sheets that open over the full player (share, sleep timer) in the dark
  // theme: a warm wine, top to bottom, lighter than the player's near-black
  // panel so the sheet stands out from what it covers.
  static const List<Color> darkSheetBackdrop = [
    Color(0xff4d1c2f),
    Color(0xff3b1523),
    Color(0xff2f111c),
  ];

  // How many friends opened the user's invitation (share sheet, settings):
  // the brand pink lightened on dark surfaces and deepened on light ones so
  // the small text stays readable.
  static const Color inviteAccent = Color(0xfff48fb1);
  static const Color inviteAccentOnLight = Color(0xffc2185b);

  // The share card's "Distribuie link-ul" button, in both themes: the brand
  // pink deepened so its white label keeps 4.5:1 contrast (plain `primary`
  // falls just short).
  static const Color shareAction = Color(0xffd81b60);

  // Status snackbar (offline, back online, station error), a Material 3
  // inverse surface: these are the dark theme's (a light snackbar), the
  // `...OnLight` ones the light theme's (a dark snackbar). Text keeps 4.5:1
  // contrast on its background, the success check mark at least 3:1.
  static const Color statusSnackbar = Color(0xffece6e9);
  static const Color statusSnackbarText = Color(0xff1c1b1d);
  static const Color statusSnackbarTextSecondary = Color(0xff4a4549);
  static const Color statusSnackbarAction = Color(0xffa3134e);
  static const Color statusSnackbarSuccess = Color(0xff1e7b3a);
  static const Color statusSnackbarOnLight = Color(0xff2e2a2d);
  static const Color statusSnackbarTextOnLight = Color(0xfff4eff2);
  // The title color at 74% opacity.
  static const Color statusSnackbarTextSecondaryOnLight = Color(0xbdf4eff2);
  static const Color statusSnackbarActionOnLight = Color(0xffffb0c8);
  static const Color statusSnackbarSuccessOnLight = Color(0xff6fdc8c);
  // Its drop shadow, in both themes.
  static const Color statusSnackbarShadow = Color(0x40000000);

  // The shadow of a station row lifted to move it, in the light theme and
  // in the dark one, where it needs to be deeper to show.
  static const Color liftedRowShadow = Color(0x38000000);
  static const Color liftedRowShadowDark = Color(0x99000000);

  // Station filter sheet: each category's hue, keyed by its group slug. The
  // sheet pales it into the circle behind the category's picture.
  static const Map<String, Color> stationGroupHues = {
    'general': Color(0xff90a4ae),
    'muzica': Color(0xffb69cff),
    'emisiuni': Color(0xff4fc3f7),
    'popular': Color(0xffff8a65),
    'predici': Color(0xff5fd3bc),
    'worship': Color(0xffffd166),
    'international': Color(0xff66d19e),
    'gospel': Color(0xffe59cff),
    'instrumental': Color(0xff8c9eff),
    'copii': Color(0xffffb45e),
    'biblia': Color(0xffd7b98e),
    'colinde': Color(0xffff6f6f),
  };
  // "Toate stațiile", and categories added later that have no hue yet.
  static const Color stationGroupAllHue = Color(0xfff48fb1);
  static const Color stationGroupFallbackHue = Color(0xffb0bec5);
  // "Resetează": the brand pink lightened on dark surfaces and deepened on
  // light ones, so the text button keeps 4.5:1 contrast.
  static const Color filterAccent = Color(0xfff48fb1);
  static const Color filterAccentOnLight = Color(0xffc2185b);

  // Grouped lists in the iOS style of the settings page: the rounded card,
  // its text, secondary text and the hairlines between rows. The `...Dark`
  // ones are the dark theme's.
  static const Color groupedCard = Color(0xfff2f2f7);
  static const Color groupedCardDark = Color(0xff1c1c1e);
  static const Color groupedText = Color(0xff1c1c1e);
  static const Color groupedTextDark = Color(0xffe8e8e8);
  static const Color groupedTextSecondary = Color(0xff6b6b6b);
  static const Color groupedTextSecondaryDark = Color(0xff8a8a8a);
  static const Color groupedDivider = Color(0xffd1d1d6);
  static const Color groupedDividerDark = Color(0xff3a3a3c);
  // A text button on those cards ("Readaugă"): the brand pink lightened on
  // dark surfaces and deepened on light ones, for 4.5:1 contrast.
  static const Color groupedAction = Color(0xfff48fb1);
  static const Color groupedActionOnLight = Color(0xffc2185b);

  // The device sheet (cast button): its drag handle, the Chromecast card,
  // the circles and pills on that card, secondary text, section labels, row
  // icons and chevrons. The `...Dark` ones are the dark theme's. Text keeps
  // 4.5:1 contrast on the card as well as on the sheet.
  static const Color deviceHandle = Color(0x1f000000);
  static const Color deviceHandleDark = Color(0x3dffffff);
  static const Color deviceCard = Color(0xfff6f3f4);
  static const Color deviceCardDark = Color(0xff262626);
  static const Color deviceCardInner = Colors.white;
  static const Color deviceCardInnerDark = Color(0xff333333);
  static const Color deviceTextSecondary = Color(0xff6b6b6b);
  static const Color deviceTextSecondaryDark = Color(0xffb3b3b3);
  static const Color deviceLabel = Color(0xff6e6e73);
  static const Color deviceLabelDark = Color(0xff9a9aa0);
  static const Color deviceIcon = Color(0xff3f3f3f);
  static const Color deviceIconDark = Color(0xffe0e0e0);
  static const Color deviceChevron = Color(0xffb0b0b5);
  static const Color deviceChevronDark = Color(0xff6a6a6f);
  // Its pink text ("Conectează", "BETA"): the brand pink lightened on dark
  // surfaces and deepened on light ones, for 4.5:1 contrast.
  static const Color deviceAccent = Color(0xfff48fb1);
  static const Color deviceAccentOnLight = Color(0xffc2185b);
  // The circle behind the lock, and the "BETA" pill.
  static const Color deviceTint = Color(0xfffdf0f4);
  static const Color deviceTintDark = Color(0xff3a1f29);
  static const Color deviceBeta = Color(0xfffce4ec);
  static const Color deviceBetaDark = Color(0xff4a1f30);
  // Its filled buttons and the circle behind a device that plays, in both
  // themes: the brand pink deepened so a white label keeps 4.5:1 contrast.
  static const Color deviceAction = Color(0xffd81b60);

  // Common colors
  static const Color error = Color(0xffd32f2f);
  static const Color success = Colors.green;
  static const Color offline = Colors.red;
}

/// Corner radii for station artwork across the app.
class AppRadius {
  AppRadius._();

  /// Small thumbnails (station list, mini players).
  static const double thumbnail = 12.0;

  /// Large artwork (full player, now-playing views).
  static const double artwork = 20.0;
}

final ThemeData lightTheme = ThemeData(
  useMaterial3: true,
  // fontFamily: 'Inter',
  brightness: Brightness.light,
  primaryColor: AppColors.primary,
  primaryColorLight: AppColors.primaryLight,
  primaryColorDark: AppColors.primaryDark,
  hintColor: AppColors.primary,
  canvasColor: AppColors.lightBackground,
  scaffoldBackgroundColor: AppColors.lightBackground,
  cardColor:const Color(0x8ae4e4e4),
  dividerColor: AppColors.lightDivider,
  highlightColor: const Color(0x66bcbcbc),
  splashColor: const Color(0x66c8c8c8),
  unselectedWidgetColor: const Color(0x8a000000),
  disabledColor: const Color(0x61000000),
  secondaryHeaderColor: Colors.white,
  appBarTheme: AppBarTheme(
      // backgroundColor: Colors.grey[200],
      surfaceTintColor: null,
      systemOverlayStyle: const SystemUiOverlayStyle(
        statusBarColor: Color(0xfffafafa),

        // Status bar brightness (optional)
        statusBarIconBrightness: Brightness.dark, // For Android (dark icons)
        statusBarBrightness: Brightness.light, // For iOS (dark icons)
      ),
      titleTextStyle: TextStyle(
        color: Colors.grey.shade800,
        fontSize: 19,
        fontWeight: FontWeight.bold,
      )),
  bottomAppBarTheme: const BottomAppBarThemeData(
    color: AppColors.playerBarLight,
  ),
  buttonTheme: const ButtonThemeData(
    textTheme: ButtonTextTheme.normal,
    minWidth: 88,
    height: 36,
    padding: EdgeInsets.only(top: 0, bottom: 0, left: 16, right: 16),
    shape: RoundedRectangleBorder(
      side: BorderSide(
        color: Color(0xff000000),
        width: 0,
        style: BorderStyle.none,
      ),
      borderRadius: BorderRadius.all(Radius.circular(2.0)),
    ),
    alignedDropdown: false,
    buttonColor: Color(0xffe0e0e0),
    disabledColor: Color(0x61000000),
    highlightColor: Color(0x29000000),
    splashColor: Color(0x1f000000),
    focusColor: Color(0x1f000000),
    hoverColor: Color(0x0a000000),
    colorScheme: ColorScheme(
      primary: Color(0xffe91e63),
      secondary: Color(0xffe91e63),
      surface: Color(0xffffffff),
      error: Color(0xffd32f2f),
      onPrimary: Color(0xffffffff),
      onSecondary: Color(0xffffffff),
      onSurface: Color(0xff000000),
      onError: Color(0xffffffff),
      brightness: Brightness.light,
    ),
  ),
  textTheme: const TextTheme(
    bodySmall: TextStyle(
      color: Color(0x8a000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    labelLarge: TextStyle(
      color: Color(0xdd000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    titleSmall: TextStyle(
      color: Color(0xff000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
  ),
  primaryTextTheme: const TextTheme(
    bodySmall: TextStyle(
      color: Color(0xb3ffffff),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    labelLarge: TextStyle(
      color: Color(0xffffffff),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    titleSmall: TextStyle(
      color: Color(0xffffffff),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
  ),
  inputDecorationTheme: const InputDecorationTheme(
    labelStyle: TextStyle(
      color: Color(0xdd000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    helperStyle: TextStyle(
      color: Color(0xdd000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    hintStyle: TextStyle(
      color: Color(0xdd000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    errorStyle: TextStyle(
      color: Color(0xdd000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    errorMaxLines: null,
    isDense: false,
    contentPadding: EdgeInsets.only(top: 12, bottom: 12, left: 0, right: 0),
    isCollapsed: false,
    prefixStyle: TextStyle(
      color: Color(0xdd000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    suffixStyle: TextStyle(
      color: Color(0xdd000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    counterStyle: TextStyle(
      color: Color(0xdd000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    filled: false,
    fillColor: Color(0x00000000),
    errorBorder: UnderlineInputBorder(
      borderSide: BorderSide(
        color: Color(0xff000000),
        width: 1,
        style: BorderStyle.solid,
      ),
      borderRadius: BorderRadius.all(Radius.circular(4.0)),
    ),
    focusedBorder: UnderlineInputBorder(
      borderSide: BorderSide(
        color: Color(0xff000000),
        width: 1,
        style: BorderStyle.solid,
      ),
      borderRadius: BorderRadius.all(Radius.circular(4.0)),
    ),
    focusedErrorBorder: UnderlineInputBorder(
      borderSide: BorderSide(
        color: Color(0xff000000),
        width: 1,
        style: BorderStyle.solid,
      ),
      borderRadius: BorderRadius.all(Radius.circular(4.0)),
    ),
    disabledBorder: UnderlineInputBorder(
      borderSide: BorderSide(
        color: Color(0xff000000),
        width: 1,
        style: BorderStyle.solid,
      ),
      borderRadius: BorderRadius.all(Radius.circular(4.0)),
    ),
    enabledBorder: UnderlineInputBorder(
      borderSide: BorderSide(
        color: Color(0xff000000),
        width: 1,
        style: BorderStyle.solid,
      ),
      borderRadius: BorderRadius.all(Radius.circular(4.0)),
    ),
    border: UnderlineInputBorder(
      borderSide: BorderSide(
        color: Color(0xff000000),
        width: 1,
        style: BorderStyle.solid,
      ),
      borderRadius: BorderRadius.all(Radius.circular(4.0)),
    ),
  ),
  iconTheme: const IconThemeData(
    color: Colors.white,
    opacity: 1,
    size: 24,
  ),
  primaryIconTheme: const IconThemeData(
    color: Color(0xffffffff),
    opacity: 1,
    size: 24,
  ),
  sliderTheme: const SliderThemeData(
    valueIndicatorTextStyle: TextStyle(
      color: Color(0xffffffff),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
  ),
  tabBarTheme: const TabBarThemeData(
    indicatorSize: TabBarIndicatorSize.tab,
    labelColor: Color(0xffffffff),
    unselectedLabelColor: Color(0xb2ffffff),
  ),
  chipTheme: const ChipThemeData(
    backgroundColor: Color(0x1f000000),
    brightness: Brightness.light,
    deleteIconColor: Color(0xde000000),
    disabledColor: Color(0x0c000000),
    labelPadding: EdgeInsets.only(top: 0, bottom: 0, left: 8, right: 8),
    labelStyle: TextStyle(
      color: Color(0xde000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    padding: EdgeInsets.only(top: 4, bottom: 4, left: 4, right: 4),
    secondaryLabelStyle: TextStyle(
      color: Color(0x3d000000),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    secondarySelectedColor: Color(0x3de91e63),
    selectedColor: Color(0x3d000000),
    shape: StadiumBorder(
        side: BorderSide(
      color: Color(0xff000000),
      width: 0,
      style: BorderStyle.none,
    )),
  ),
  dialogTheme: const DialogThemeData(
      shape: RoundedRectangleBorder(
    side: BorderSide(
      color: Color(0xff000000),
      width: 0,
      style: BorderStyle.none,
    ),
    borderRadius: BorderRadius.all(Radius.circular(0.0)),
  )),
  checkboxTheme: CheckboxThemeData(
    fillColor: WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) {
        return null;
      }
      if (states.contains(WidgetState.selected)) {
        return const Color(0xffd81b60);
      }
      return null;
    }),
  ),
  radioTheme: RadioThemeData(
    fillColor: WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) {
        return null;
      }
      if (states.contains(WidgetState.selected)) {
        return const Color(0xffd81b60);
      }
      return null;
    }),
  ),
  colorScheme: ColorScheme.fromSwatch(primarySwatch: Colors.pink)
      .copyWith(error: const Color(0xffd32f2f)),
  textSelectionTheme: const TextSelectionThemeData(
    cursorColor: Color(0xff4285f4),
    selectionColor: Color(0xfff48fb1),
    selectionHandleColor: Color(0xfff06292),
  ),
);

final ThemeData darkTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  primaryColor: AppColors.primary,
  primaryColorLight: AppColors.primaryLight,
  primaryColorDark: AppColors.primaryDark,
  hintColor: AppColors.primary,
  canvasColor: AppColors.darkBackground,
  scaffoldBackgroundColor: AppColors.darkBackground,
  cardColor: AppColors.darkSurface,
  dividerColor: AppColors.darkDivider,
  highlightColor: const Color(0x40cccccc),
  splashColor: const Color(0x40cccccc),
  unselectedWidgetColor: const Color(0xb3ffffff),
  disabledColor: const Color(0x62ffffff),
  secondaryHeaderColor: const Color(0xff616161),
  appBarTheme: AppBarTheme(
    surfaceTintColor: null,
    systemOverlayStyle: const SystemUiOverlayStyle(
      statusBarColor: Color(0xff121212),
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ),
    titleTextStyle: TextStyle(
      color: Colors.grey.shade200,
      fontSize: 19,
      fontWeight: FontWeight.bold,
    ),
  ),
  bottomAppBarTheme: const BottomAppBarThemeData(
    color: AppColors.playerBar,
  ),
  buttonTheme: const ButtonThemeData(
    textTheme: ButtonTextTheme.normal,
    minWidth: 88,
    height: 36,
    padding: EdgeInsets.only(top: 0, bottom: 0, left: 16, right: 16),
    shape: RoundedRectangleBorder(
      side: BorderSide(
        color: Color(0xff000000),
        width: 0,
        style: BorderStyle.none,
      ),
      borderRadius: BorderRadius.all(Radius.circular(2.0)),
    ),
    alignedDropdown: false,
    buttonColor: Color(0xff1e1e1e),
    disabledColor: Color(0x61ffffff),
    highlightColor: Color(0x29ffffff),
    splashColor: Color(0x1fffffff),
    focusColor: Color(0x1fffffff),
    hoverColor: Color(0x0affffff),
    colorScheme: ColorScheme(
      primary: Color(0xffe91e63),
      secondary: Color(0xffe91e63),
      surface: Color(0xff1e1e1e),
      error: Color(0xffd32f2f),
      onPrimary: Color(0xff000000),
      onSecondary: Color(0xff000000),
      onSurface: Color(0xffffffff),
      onError: Color(0xff000000),
      brightness: Brightness.dark,
    ),
  ),
  textTheme: const TextTheme(
    bodySmall: TextStyle(
      color: Color(0xb3ffffff),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    labelLarge: TextStyle(
      color: Color(0xffffffff),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    titleSmall: TextStyle(
      color: Color(0xffffffff),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
  ),
  primaryTextTheme: const TextTheme(
    bodySmall: TextStyle(
      color: Color(0xb3ffffff),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    labelLarge: TextStyle(
      color: Color(0xffffffff),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
    titleSmall: TextStyle(
      color: Color(0xffffffff),
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    ),
  ),
  iconTheme: const IconThemeData(
    color: Colors.white,
    opacity: 1,
    size: 24,
  ),
  primaryIconTheme: const IconThemeData(
    color: Colors.white,
    opacity: 1,
    size: 24,
  ),
  colorScheme: ColorScheme.fromSwatch(
    primarySwatch: Colors.pink,
    brightness: Brightness.dark,
  ).copyWith(
    error: const Color(0xffd32f2f),
  ),
);
