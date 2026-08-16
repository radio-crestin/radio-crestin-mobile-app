import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/player_video_surface.dart';
import 'package:radio_crestin/widgets/playlist_player_section.dart';
import 'package:radio_crestin/types/playlist_item.dart';

PlaylistItem _item(int id, PlaylistItemType type) => PlaylistItem(
      id: id,
      order: id,
      type: type,
      url: 'https://youtu.be/vid$id',
      title: 'Item $id',
    );

void main() {
  group('showYoutubeBackgroundNotice (chip visibility rule)', () {
    test('shown for an active single YouTube video item', () {
      expect(
        showYoutubeBackgroundNotice(
          isYoutubeContent: true,
          item: _item(1, PlaylistItemType.youtube),
        ),
        isTrue,
      );
    });

    test('shown for an active YouTube playlist item', () {
      expect(
        showYoutubeBackgroundNotice(
          isYoutubeContent: true,
          item: _item(2, PlaylistItemType.youtubePlaylist),
        ),
        isTrue,
      );
    });

    test('hidden for audio items', () {
      expect(
        showYoutubeBackgroundNotice(
          isYoutubeContent: false,
          item: _item(3, PlaylistItemType.audio),
        ),
        isFalse,
      );
    });

    test('hidden for video items', () {
      expect(
        showYoutubeBackgroundNotice(
          isYoutubeContent: false,
          item: _item(4, PlaylistItemType.video),
        ),
        isFalse,
      );
    });

    test('hidden when there is no current item', () {
      expect(
        showYoutubeBackgroundNotice(isYoutubeContent: true, item: null),
        isFalse,
      );
    });

    test('hidden on a stream/item-type mismatch (flag true, non-youtube item)',
        () {
      // Guards a transient mismatch during a crossfade: the notice only shows
      // when BOTH the youtube flag is set and the item is actually youtube.
      expect(
        showYoutubeBackgroundNotice(
          isYoutubeContent: true,
          item: _item(5, PlaylistItemType.audio),
        ),
        isFalse,
      );
    });
  });

  group('YoutubeBackgroundChip widget', () {
    testWidgets('renders the Romanian background-notice label', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: YoutubeBackgroundChip())),
      ));
      expect(find.text('Nu rulează în fundal'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
    });
  });
}
