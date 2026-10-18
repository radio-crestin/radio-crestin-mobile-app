import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/android_auto_browse.dart';
import 'package:radio_crestin/services/car_play_layout.dart';

/// The Android Auto pieces that follow CarPlay: browse ids, the wording and
/// the Now Playing buttons.
void main() {
  const stream = 'https://stream.example.com/rve/stream.mp3';

  group('AndroidAutoBrowseIds.parseItem', () {
    test('a favorite keeps next and previous within the favorites', () {
      final pick = AndroidAutoBrowseIds.parseItem(
          AndroidAutoBrowseIds.favoriteItem(stream));

      expect(pick.stationMediaId, stream);
      expect(pick.fromFavorites, isTrue);
      expect(pick.fromGroup, isNull);
    });

    test('a category station keeps its slug; the URL keeps its colons', () {
      final id = AndroidAutoBrowseIds.groupItem('copii', stream);
      final pick = AndroidAutoBrowseIds.parseItem(id);

      expect(id, 'group:copii:$stream');
      expect(pick.stationMediaId, stream);
      expect(pick.fromFavorites, isFalse);
      expect(pick.fromGroup, 'copii');
    });

    test('a plain stream URL is a pick from the full list', () {
      final pick = AndroidAutoBrowseIds.parseItem(stream);

      expect(pick.stationMediaId, stream);
      expect(pick.fromFavorites, isFalse);
      expect(pick.fromGroup, isNull);
    });

    test('a history row id passes through unchanged', () {
      const id = 'history_rve_1791720000';
      final pick = AndroidAutoBrowseIds.parseItem(id);

      expect(pick.stationMediaId, id);
      expect(pick.fromFavorites, isFalse);
      expect(pick.fromGroup, isNull);
    });

    test('a category folder id is no station', () {
      final pick = AndroidAutoBrowseIds.parseItem('group:copii');

      expect(pick.fromGroup, isNull);
    });
  });

  group('AndroidAutoBrowseIds.groupSlugOf', () {
    test('reads the slug of a category folder', () {
      expect(
        AndroidAutoBrowseIds.groupSlugOf(AndroidAutoBrowseIds.group('copii')),
        'copii',
      );
    });

    test('a station of a category, another folder or no slug is no folder', () {
      expect(
        AndroidAutoBrowseIds.groupSlugOf(
            AndroidAutoBrowseIds.groupItem('copii', stream)),
        isNull,
      );
      expect(AndroidAutoBrowseIds.groupSlugOf(AndroidAutoBrowseIds.categories),
          isNull);
      expect(AndroidAutoBrowseIds.groupSlugOf('group:'), isNull);
    });
  });

  group('CarStrings', () {
    test("CarPlay's wording", () {
      expect(CarStrings.favorites, 'Favorite');
      expect(CarStrings.allStations, 'Toate radiourile');
      expect(CarStrings.categories, 'Categorii');
      expect(CarStrings.songHistory, 'Redate recent');
      expect(CarStrings.starred('RVE Brasov'), '★ RVE Brasov');
    });

    test('Android Auto puts the star after the name, for its A·Z index', () {
      expect(CarStrings.starredOnAndroidAuto('RVE Brasov'), 'RVE Brasov ★');
    });
  });

  group('CarCategoryLayout.all', () {
    CarCategory category(int id) => CarCategory(
          id: id,
          slug: 'c$id',
          name: 'C$id',
          stationIds: {id},
        );

    test('the grid buttons, then the categories behind More', () {
      final groups = [for (var id = 1; id <= 10; id++) category(id)];
      final layout = CarCategoryLayout.compute(
        groups: groups,
        knownStationIds: {for (var id = 1; id <= 10; id++) id},
      );

      expect(layout.more, isNotEmpty);
      expect(layout.all.map((c) => c.slug),
          [...layout.onGrid, ...layout.more].map((c) => c.slug));
      expect(layout.all, hasLength(10));
    });
  });

  group('AppAudioHandler.sessionControls', () {
    List<String?> customNames(List<MediaControl> controls) => [
          for (final c in controls)
            if (c.action == MediaAction.custom) c.customAction?.name,
        ];

    List<MediaAction> actionsAt(
      List<MediaControl> controls,
      List<int> indices,
    ) =>
        [for (final i in indices) controls[i].action];

    test("on Android Auto: CarPlay's like, favorite, dislike", () {
      final result = AppAudioHandler.sessionControls(
        onAndroidAuto: true,
        playing: true,
        isFav: false,
        isLiked: false,
        isDisliked: false,
      );

      expect(customNames(result.controls),
          ['likeSong', 'toggleFavorite', 'dislikeSong']);
      expect(result.compact, [2, 3, 4]);
      expect(actionsAt(result.controls, result.compact), [
        MediaAction.skipToPrevious,
        MediaAction.pause,
        MediaAction.skipToNext,
      ]);
    });

    test('on the phone: the notification keeps its buttons', () {
      final result = AppAudioHandler.sessionControls(
        onAndroidAuto: false,
        playing: true,
        isFav: false,
        isLiked: false,
        isDisliked: false,
      );

      expect(customNames(result.controls),
          ['toggleFavorite', 'showSongHistory', 'likeSong', 'dislikeSong']);
      expect(result.controls, hasLength(7));
      expect(result.compact, [3, 4, 5]);
    });

    test('the compact buttons follow play or pause in both modes', () {
      for (final onAndroidAuto in [true, false]) {
        final result = AppAudioHandler.sessionControls(
          onAndroidAuto: onAndroidAuto,
          playing: false,
          isFav: false,
          isLiked: false,
          isDisliked: false,
        );

        expect(actionsAt(result.controls, result.compact), [
          MediaAction.skipToPrevious,
          MediaAction.play,
          MediaAction.skipToNext,
        ]);
      }
    });

    test('the icons and labels show the favorite and the vote', () {
      final result = AppAudioHandler.sessionControls(
        onAndroidAuto: true,
        playing: true,
        isFav: true,
        isLiked: true,
        isDisliked: false,
      );
      MediaControl named(String name) =>
          result.controls.firstWhere((c) => c.customAction?.name == name);

      expect(named('toggleFavorite').androidIcon, 'drawable/ic_favorite');
      expect(named('toggleFavorite').label, 'Elimină din favorite');
      expect(named('likeSong').androidIcon, 'drawable/ic_thumb_up');
      expect(named('likeSong').label, 'Retrage like');
      expect(
          named('dislikeSong').androidIcon, 'drawable/ic_thumb_down_outline');
      expect(named('dislikeSong').label, 'Nu îmi place');
    });
  });
}
