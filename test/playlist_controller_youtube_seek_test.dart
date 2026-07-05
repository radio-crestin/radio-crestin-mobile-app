import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/playlist_controller.dart';
import 'package:radio_crestin/services/playlist_sync_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/types/playlist_item.dart';

PlaylistItem _item(int id, PlaylistItemType type) => PlaylistItem(
      id: id,
      order: id,
      type: type,
      url: 'https://youtu.be/vid$id',
      title: 'Item $id',
    );

void main() {
  // The YouTube branches of PlaylistController.seek never touch the handler, so
  // this exercises the seek routing purely (no GetIt / AppAudioHandler needed).
  group('PlaylistController.seek YouTube routing', () {
    late PlaylistController controller;

    setUp(() {
      controller = PlaylistController(
        videoService: VideoPlaybackService(),
        syncService: PlaylistSyncService(),
      );
    });

    tearDown(() => controller.dispose());

    test('single youtube video emits a seek request + optimistic position',
        () async {
      controller.currentItem.add(_item(1, PlaylistItemType.youtube));
      final seeks = <Duration>[];
      final sub = controller.youtubeSeek.stream.listen(seeks.add);

      await controller.seek(const Duration(seconds: 42));
      await Future<void>.delayed(Duration.zero);

      expect(seeks, [const Duration(seconds: 42)]);
      expect(controller.position.value, const Duration(seconds: 42));
      await sub.cancel();
    });

    test('youtube_playlist seek is a no-op (item-level timeline meaningless)',
        () async {
      controller.currentItem.add(_item(2, PlaylistItemType.youtubePlaylist));
      final seeks = <Duration>[];
      final sub = controller.youtubeSeek.stream.listen(seeks.add);

      await controller.seek(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);

      expect(seeks, isEmpty);
      expect(controller.position.value, Duration.zero);
      await sub.cancel();
    });

    test('no current item → seek does nothing', () async {
      final seeks = <Duration>[];
      final sub = controller.youtubeSeek.stream.listen(seeks.add);

      await controller.seek(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      expect(seeks, isEmpty);
      await sub.cancel();
    });
  });
}
