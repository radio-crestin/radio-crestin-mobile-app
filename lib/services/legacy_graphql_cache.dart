import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The GraphQL cache that versions up to 1.6.1 kept on disk, in a Hive box.
///
/// Nothing read it back, yet every song and artist the station list ever
/// carried stayed in it, so it grew for as long as the app was used. Opening
/// it parsed the whole file in one go on the UI isolate, which since
/// Flutter 3.29 is Android's main thread: on a slow phone, a launch with a
/// file of a few MB froze long enough for an ANR ("Input dispatching timed
/// out"). The app now keeps the GraphQL cache in memory, and this removes
/// the old file without reading it.
abstract final class LegacyGraphqlCache {
  /// The box file, the compaction file Hive writes beside it, and its lock.
  static const fileNames = [
    'graphqlclientstore.hive',
    'graphqlclientstore.hivec',
    'graphqlclientstore.lock',
  ];

  /// Deletes the old cache files. Never throws: a file left behind costs
  /// only disk space, as nothing opens it any more.
  static Future<void> delete() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      for (final name in fileNames) {
        await _deleteIfPresent(File('${directory.path}/$name'));
      }
    } catch (_) {
      // No documents directory (an unsupported platform): nothing to delete.
    }
  }

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Retried at the next launch.
    }
  }
}
