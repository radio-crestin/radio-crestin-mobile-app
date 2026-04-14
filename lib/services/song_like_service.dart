import 'dart:developer' as developer;

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Like status for a song: -1 = dislike, 0 = neutral, 1 = like
class SongLike {
  final int stationId;
  final int songId;
  final int likeStatus; // -1, 0, 1
  final String? thumbnailUrl;
  final String? songTitle;
  final String? songArtist;
  final DateTime updatedAt;

  const SongLike({
    required this.stationId,
    required this.songId,
    required this.likeStatus,
    this.thumbnailUrl,
    this.songTitle,
    this.songArtist,
    required this.updatedAt,
  });
}

class SongLikeService {
  static SongLikeService? _instance;
  static SongLikeService get instance => _instance!;

  Database? _db;
  // In-memory cache for instant lookups by the media service
  final Map<int, int> _cache = {}; // songId -> likeStatus

  SongLikeService._();

  static Future<SongLikeService> init() async {
    final service = SongLikeService._();
    await service._initDb();
    _instance = service;
    return service;
  }

  Future<void> _initDb() async {
    final dbPath = join(await getDatabasesPath(), 'song_likes.db');
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE song_likes (
            song_id INTEGER PRIMARY KEY,
            station_id INTEGER NOT NULL,
            like_status INTEGER NOT NULL DEFAULT 0,
            thumbnail_url TEXT,
            song_title TEXT,
            song_artist TEXT,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_station_id ON song_likes(station_id)',
        );
      },
    );
    // Load cache
    final rows = await _db!.query('song_likes', columns: ['song_id', 'like_status']);
    for (final row in rows) {
      _cache[row['song_id'] as int] = row['like_status'] as int;
    }
    _log('init: loaded ${_cache.length} entries into cache');
  }

  static void _log(String message) {
    developer.log("SongLikeService: $message");
  }

  /// Returns like status instantly from in-memory cache.
  /// -1 = dislike, 0 = neutral/unknown, 1 = like
  int getLikeStatus(int songId) {
    if (songId <= 0) return 0;
    return _cache[songId] ?? 0;
  }

  /// Sets like status for a song. Updates both cache and database.
  Future<void> setLikeStatus({
    required int stationId,
    required int songId,
    required int likeStatus,
    String? thumbnailUrl,
    String? songTitle,
    String? songArtist,
  }) async {
    if (songId <= 0) return;
    _cache[songId] = likeStatus;
    await _db?.insert(
      'song_likes',
      {
        'song_id': songId,
        'station_id': stationId,
        'like_status': likeStatus,
        'thumbnail_url': thumbnailUrl,
        'song_title': songTitle,
        'song_artist': songArtist,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Gets all liked songs (likeStatus == 1), most recent first.
  Future<List<SongLike>> getLikedSongs({int limit = 100}) async {
    final rows = await _db?.query(
      'song_likes',
      where: 'like_status = 1',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return _mapRows(rows);
  }

  /// Gets all disliked songs (likeStatus == -1), most recent first.
  Future<List<SongLike>> getDislikedSongs({int limit = 100}) async {
    final rows = await _db?.query(
      'song_likes',
      where: 'like_status = -1',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return _mapRows(rows);
  }

  List<SongLike> _mapRows(List<Map<String, Object?>>? rows) {
    if (rows == null) return [];
    return rows.map((row) => SongLike(
      stationId: row['station_id'] as int,
      songId: row['song_id'] as int,
      likeStatus: row['like_status'] as int,
      thumbnailUrl: row['thumbnail_url'] as String?,
      songTitle: row['song_title'] as String?,
      songArtist: row['song_artist'] as String?,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    )).toList();
  }
}
