import 'package:flutter/services.dart';

class VibrationPattern {
  static Future<void> vibrate() async {
    HapticFeedback.vibrate();
  }

  static Future<void> lightImpact() async {
    HapticFeedback.lightImpact();
  }

  static Future<void> mediumImpact() async {
    HapticFeedback.mediumImpact();
  }

  static Future<void> heavyImpact() async {
    HapticFeedback.heavyImpact();
  }

  static Future<void> selectionClick() async {
    HapticFeedback.selectionClick();
  }

  static Future<void> scanningProduct() async {
    for (int i = 0; i < 4; i++) {
      HapticFeedback.selectionClick();
      await Future.delayed(Duration(milliseconds: 350));
    }
  }

  static Future<void> errorPattern() async {
    HapticFeedback.mediumImpact();
    await Future.delayed(Duration(milliseconds: 100));
    HapticFeedback.lightImpact();
    await Future.delayed(Duration(milliseconds: 100));
    HapticFeedback.lightImpact();
  }
}