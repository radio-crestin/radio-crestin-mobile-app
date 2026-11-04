/// Whether [stream], an entry of a station's `station_streams`, is an HLS
/// stream. Every other type (`direct_stream`, `proxied_stream`) is a direct,
/// MP3-style stream.
bool isHlsStream(Object? stream) =>
    stream is Map && stream['type']?.toString() == 'HLS';

/// Returns [streams] in the order a load tries them.
///
/// They come HLS first (see `Utils.getStationStreamObjects`). With
/// [directFirst] the direct streams move ahead of the HLS ones; each group
/// keeps its own order, so the station's preferred direct stream still
/// comes first.
List<T> orderStreams<T>(List<T> streams, {required bool directFirst}) {
  if (!directFirst) return streams;
  return [
    ...streams.where((stream) => !isHlsStream(stream)),
    ...streams.where(isHlsStream),
  ];
}
