import 'package:flutter/material.dart';

class ScreenUtils {
  static const double smallDeviceThreshold = 380.0;
  
  static bool isSmallDevice(BuildContext context) {
    return MediaQuery.of(context).size.width < smallDeviceThreshold;
  }
}