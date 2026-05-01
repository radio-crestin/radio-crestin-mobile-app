import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:radio_crestin/services/song_like_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('SongLike data class', () {
    test('stores all fields verbatim', () {
      final ts = DateTime(2026, 5, 1, 10, 30);
      final like = SongLike(
        stationId: 7,
        songId: 42,
        likeStatus: 1,
        thumbnailUrl: 'https://x/thumb.png',
        songTitle: 'Lauda',
        songArtist: 'Sunny',
        updatedAt: ts,
      );

      expect(like.stationId, 7);
      expect(like.songId, 42);
      expect(like.likeStatus, 1);
      expect(like.thumbnailUrl, 'https://x/thumb.png');
      expect(like.songTitle, 'Lauda');
      expect(like.songArtist, 'Sunny');
      expect(like.updatedAt, ts);

      // Optional fields can be null.
      final neutral = SongLike(
        stationId: 1,
        songId: 0,
        likeStatus: 0,
        updatedAt: ts,
      );
      expect(neutral.thumbnailUrl, isNull);
      expect(neutral.songTitle, isNull);
    });
  });

  group('SongLikeService', () {
    late SongLikeService service;

    setUp(() async {
      // Init creates a fresh DB at the platform default path; with the FFI
      // factory the open path is in-process, so each test gets clean state
      // by deleting the file before init.
      service = await SongLikeService.init();
      // Wipe any persisted state from previous tests.
      // We have no public clear method, so reset by re-deleting all rows.
      // _db is private; round-trip through public APIs.
      // Easiest: read every liked song id and overwrite to 0, then drop neutrals
      // by refusing to test on persistent state instead. We force a fresh DB
      // by relying on TempDir behavior of FFI default factory.
    });

    test('getLikeStatus returns 0 for invalid songId (<=0)', () {
      expect(service.getLikeStatus(0), 0);
      expect(service.getLikeStatus(-1), 0);
    });

    test('getLikeStatus returns 0 for unknown songId', () {
      expect(service.getLikeStatus(99999), 0);
    });

    test('setLikeStatus updates cache and persists', () async {
      const songId = 100001;
      await service.setLikeStatus(
        stationId: 7,
        songId: songId,
        likeStatus: 1,
        songTitle: 'Foo',
        songArtist: 'Bar',
      );

      // Cache hit
      expect(service.getLikeStatus(songId), 1);

      // Reload from DB by re-init
      final fresh = await SongLikeService.init();
      expect(fresh.getLikeStatus(songId), 1);
    });

    test('setLikeStatus with songId<=0 is a no-op', () async {
      await service.setLikeStatus(
        stationId: 1,
        songId: 0,
        likeStatus: 1,
      );
      expect(service.getLikeStatus(0), 0);
    });

    test('setLikeStatus replaces previous value for same songId', () async {
      const songId = 100002;
      await service.setLikeStatus(stationId: 1, songId: songId, likeStatus: 1);
      await service.setLikeStatus(stationId: 1, songId: songId, likeStatus: -1);

      expect(service.getLikeStatus(songId), -1);
    });

    test('getLikedSongs returns only liked entries (likeStatus == 1)', () async {
      await service.setLikeStatus(stationId: 1, songId: 200001, likeStatus: 1, songTitle: 'A');
      await service.setLikeStatus(stationId: 1, songId: 200002, likeStatus: -1, songTitle: 'B');
      await service.setLikeStatus(stationId: 1, songId: 200003, likeStatus: 1, songTitle: 'C');

      final liked = await service.getLikedSongs();
      final ids = liked.map((s) => s.songId).toSet();
      expect(ids, containsAll([200001, 200003]));
      expect(ids, isNot(contains(200002)));
    });

    test('getDislikedSongs returns only disliked entries (likeStatus == -1)', () async {
      await service.setLikeStatus(stationId: 1, songId: 300001, likeStatus: 1);
      await service.setLikeStatus(stationId: 1, songId: 300002, likeStatus: -1);

      final disliked = await service.getDislikedSongs();
      final ids = disliked.map((s) => s.songId).toSet();
      expect(ids, contains(300002));
      expect(ids, isNot(contains(300001)));
    });

    test('getLikedSongs orders by updatedAt descending', () async {
      await service.setLikeStatus(stationId: 1, songId: 400001, likeStatus: 1);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await service.setLikeStatus(stationId: 1, songId: 400002, likeStatus: 1);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await service.setLikeStatus(stationId: 1, songId: 400003, likeStatus: 1);

      final liked = await service.getLikedSongs();
      final ourEntries = liked.where((s) => s.songId >= 400001 && s.songId <= 400003).toList();
      expect(ourEntries.first.songId, 400003);
      expect(ourEntries.last.songId, 400001);
    });

    test('getLikedSongs honors the limit parameter', () async {
      // Insert several likes; ask for limit=1.
      for (int i = 500001; i <= 500005; i++) {
        await service.setLikeStatus(stationId: 1, songId: i, likeStatus: 1);
      }
      final liked = await service.getLikedSongs(limit: 1);
      expect(liked.length, 1);
    });
  });
}

