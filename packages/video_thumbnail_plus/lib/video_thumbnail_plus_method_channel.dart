import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'video_thumbnail_plus.dart';
import 'video_thumbnail_plus_platform_interface.dart';

/// An implementation of [VideoThumbnailPlusPlatform] that uses method channels.
class MethodChannelVideoThumbnailPlus extends VideoThumbnailPlusPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel =
      const MethodChannel('world.nailao.flutter.plugin/video_thumbnail_plus');

  @override
  Future<String?> thumbnailFile({
    required String video,
    Map<String, String>? headers,
    String? thumbnailPath,
    ImageFormat imageFormat = ImageFormat.PNG,
    int maxHeight = 0,
    int maxWidth = 0,
    int timeMs = 0,
    int quality = 100,
  }) async {
    final result = await methodChannel.invokeMethod<String>(
      'file',
      <String, dynamic>{
        'video': video,
        'headers': headers ?? <String, String>{},
        'path': thumbnailPath ?? '',
        'format': imageFormat.index,
        'maxh': maxHeight,
        'maxw': maxWidth,
        'timeMs': timeMs,
        'quality': quality,
      },
    );
    return result;
  }

  @override
  Future<Uint8List?> thumbnailData({
    required String video,
    Map<String, String>? headers,
    ImageFormat imageFormat = ImageFormat.PNG,
    int maxHeight = 0,
    int maxWidth = 0,
    int timeMs = 0,
    int quality = 100,
  }) async {
    final result = await methodChannel.invokeMethod<Uint8List>(
      'data',
      <String, dynamic>{
        'video': video,
        'headers': headers ?? <String, String>{},
        'format': imageFormat.index,
        'maxh': maxHeight,
        'maxw': maxWidth,
        'timeMs': timeMs,
        'quality': quality,
      },
    );
    return result;
  }
}
