import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'video_thumbnail_plus.dart';
import 'video_thumbnail_plus_method_channel.dart';

abstract class VideoThumbnailPlusPlatform extends PlatformInterface {
  /// Constructs a VideoThumbnailPlusPlatform.
  VideoThumbnailPlusPlatform() : super(token: _token);

  static final Object _token = Object();

  static VideoThumbnailPlusPlatform _instance =
      MethodChannelVideoThumbnailPlus();

  /// The default instance of [VideoThumbnailPlusPlatform] to use.
  ///
  /// Defaults to [MethodChannelVideoThumbnailPlus].
  static VideoThumbnailPlusPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [VideoThumbnailPlusPlatform] when
  /// they register themselves.
  static set instance(VideoThumbnailPlusPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Generates a thumbnail file from a video.
  Future<String?> thumbnailFile({
    required String video,
    Map<String, String>? headers,
    String? thumbnailPath,
    ImageFormat imageFormat = ImageFormat.PNG,
    int maxHeight = 0,
    int maxWidth = 0,
    int timeMs = 0,
    int quality = 100,
  }) {
    throw UnimplementedError('thumbnailFile() has not been implemented.');
  }

  /// Generates thumbnail data from a video.
  Future<Uint8List?> thumbnailData({
    required String video,
    Map<String, String>? headers,
    ImageFormat imageFormat = ImageFormat.PNG,
    int maxHeight = 0,
    int maxWidth = 0,
    int timeMs = 0,
    int quality = 100,
  }) {
    throw UnimplementedError('thumbnailData() has not been implemented.');
  }
}
