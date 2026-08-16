import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_thumbnail_plus/video_thumbnail_plus.dart';
import 'package:video_thumbnail_plus/video_thumbnail_plus_platform_interface.dart';
import 'package:video_thumbnail_plus/video_thumbnail_plus_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockVideoThumbnailPlusPlatform
    with MockPlatformInterfaceMixin
    implements VideoThumbnailPlusPlatform {
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
    return '/mock/path/thumbnail.png';
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
    return Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]); // PNG magic bytes
  }
}

void main() {
  final VideoThumbnailPlusPlatform initialPlatform =
      VideoThumbnailPlusPlatform.instance;

  test('$MethodChannelVideoThumbnailPlus is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelVideoThumbnailPlus>());
  });

  test('thumbnailFile returns path', () async {
    MockVideoThumbnailPlusPlatform fakePlatform =
        MockVideoThumbnailPlusPlatform();
    VideoThumbnailPlusPlatform.instance = fakePlatform;

    final result = await VideoThumbnailPlus.thumbnailFile(
      video: 'test.mp4',
    );
    expect(result, '/mock/path/thumbnail.png');
  });

  test('thumbnailData returns bytes', () async {
    MockVideoThumbnailPlusPlatform fakePlatform =
        MockVideoThumbnailPlusPlatform();
    VideoThumbnailPlusPlatform.instance = fakePlatform;

    final result = await VideoThumbnailPlus.thumbnailData(
      video: 'test.mp4',
    );
    expect(result, isNotNull);
    expect(result!.length, 4);
  });
}
