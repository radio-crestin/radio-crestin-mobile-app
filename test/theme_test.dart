import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/theme.dart';

void main() {
  group('AppColors', () {
    test('primary is the brand pink', () {
      expect(AppColors.primary, const Color(0xffe91e63));
    });

    test('primaryLight is light pink', () {
      expect(AppColors.primaryLight, const Color(0xfff8bbd0));
    });

    test('primaryDark is dark pink', () {
      expect(AppColors.primaryDark, const Color(0xff8f0133));
    });

    test('error is red', () {
      expect(AppColors.error, const Color(0xffd32f2f));
    });

    test('success is green', () {
      expect(AppColors.success, Colors.green);
    });

    test('offline is red', () {
      expect(AppColors.offline, Colors.red);
    });

    test('light theme colors are defined', () {
      expect(AppColors.lightBackground, const Color(0xfffafafa));
      expect(AppColors.lightSurface, Colors.white);
      expect(AppColors.lightText, const Color(0xff000000));
    });

    test('dark theme colors are defined', () {
      expect(AppColors.darkBackground, const Color(0xff121212));
      expect(AppColors.darkSurface, const Color(0xff1e1e1e));
      expect(AppColors.darkText, Colors.white);
    });
  });

  group('lightTheme', () {
    test('uses Material 3', () {
      expect(lightTheme.useMaterial3, true);
    });

    test('has light brightness', () {
      expect(lightTheme.brightness, Brightness.light);
    });

    test('has correct primary color', () {
      expect(lightTheme.primaryColor, AppColors.primary);
    });

    test('scaffold background is light', () {
      expect(lightTheme.scaffoldBackgroundColor, AppColors.lightBackground);
    });

    test('bottom app bar uses primary color', () {
      expect(lightTheme.bottomAppBarTheme.color, const Color(0xffe91e63));
    });

    test('icon theme defaults to 24px white', () {
      expect(lightTheme.iconTheme.size, 24);
      expect(lightTheme.iconTheme.color, Colors.white);
    });

    test('app bar title style is bold 19px', () {
      expect(lightTheme.appBarTheme.titleTextStyle?.fontSize, 19);
      expect(lightTheme.appBarTheme.titleTextStyle?.fontWeight, FontWeight.bold);
    });
  });

  group('darkTheme', () {
    test('uses Material 3', () {
      expect(darkTheme.useMaterial3, true);
    });

    test('has dark brightness', () {
      expect(darkTheme.brightness, Brightness.dark);
    });

    test('has correct primary color', () {
      expect(darkTheme.primaryColor, AppColors.primary);
    });

    test('scaffold background is dark', () {
      expect(darkTheme.scaffoldBackgroundColor, AppColors.darkBackground);
    });

    test('card color is dark surface', () {
      expect(darkTheme.cardColor, AppColors.darkSurface);
    });

    test('bottom app bar uses dark primary', () {
      expect(darkTheme.bottomAppBarTheme.color, const Color(0xff75002c));
    });
  });

  group('CustomThemeColors extension', () {
    test('light theme cardColorSelected is correct', () {
      expect(lightTheme.cardColorSelected, const Color(0xFFCFCFCF));
    });

    test('dark theme cardColorSelected is correct', () {
      expect(darkTheme.cardColorSelected, const Color(0xFF353535));
    });
  });
}
