import 'dart:convert';
import 'dart:typed_data';

import 'media.g.dart';

/// A live HLS stream like the Radio Crestin origin's: an 11-minute sliding
/// window of 6 s segments with program dates, which the app plays a few
/// minutes behind live.
///
/// Segments are packed audio (AAC with an ID3 timestamp), which AVPlayer
/// and ExoPlayer play like the origin's MPEG-TS: every segment carries the
/// same audio, stamped with its own place on the timeline.
class LiveHlsStream {
  LiveHlsStream({DateTime? now}) : _start = (now ?? DateTime.now()).toUtc();

  /// 94 AAC frames of 1024 samples at 16 kHz.
  static const segmentDuration = Duration(microseconds: 6016000);
  static const windowSegments = 110;

  static final Uint8List _audio = _firstAdtsFrames(
    base64Decode(aacSegmentBase64),
    94,
  );

  /// When the stream "went live": the window is already full at start.
  final DateTime _start;

  int? _frozenAt;

  /// Whether the playlist stopped moving: the origin serves the same
  /// window forever, as when its encoder dies.
  bool get isFrozen => _frozenAt != null;

  void freeze({DateTime? now}) => _frozenAt ??= liveSequence(now);
  void unfreeze() => _frozenAt = null;

  /// The sequence number of the newest complete segment at [now].
  int liveSequence([DateTime? now]) {
    final elapsed = (now ?? DateTime.now()).toUtc().difference(_start);
    return windowSegments +
        elapsed.inMicroseconds ~/ segmentDuration.inMicroseconds;
  }

  /// The media playlist at [now].
  String playlist({DateTime? now}) {
    final last = _frozenAt ?? liveSequence(now);
    final first = last - windowSegments + 1;
    final seconds = segmentDuration.inMicroseconds / 1e6;
    final lines = [
      '#EXTM3U',
      '#EXT-X-VERSION:6',
      '#EXT-X-TARGETDURATION:6',
      '#EXT-X-MEDIA-SEQUENCE:$first',
      '#EXT-X-START:TIME-OFFSET=-18',
      for (var sequence = first; sequence <= last; sequence++) ...[
        '#EXTINF:${seconds.toStringAsFixed(3)},',
        '#EXT-X-PROGRAM-DATE-TIME:${_programDate(sequence)}',
        '$sequence.aac',
      ],
    ];
    return '${lines.join('\n')}\n';
  }

  /// Segment [sequence]: its timestamp, then the audio.
  Uint8List segment(int sequence) {
    final pts = sequence * segmentDuration.inMicroseconds * 9 ~/ 100;
    return Uint8List.fromList([..._id3Timestamp(pts), ..._audio]);
  }

  /// When segment [sequence] starts: the newest one ends by now.
  String _programDate(int sequence) {
    final offset = segmentDuration * (sequence - windowSegments - 1);
    return _start.add(offset).toIso8601String();
  }

  /// The ID3 tag HLS packed audio opens with: a PRIV frame holding the
  /// 33-bit MPEG-2 timestamp of the segment's first sample.
  static List<int> _id3Timestamp(int pts) {
    final owner = ascii.encode('com.apple.streaming.transportStreamTimestamp');
    final timestamp = ByteData(8)..setUint64(0, pts & 0x1FFFFFFFF);
    final frameBody = [...owner, 0, ...timestamp.buffer.asUint8List()];
    final frame = [...ascii.encode('PRIV'), ..._syncSafe(frameBody.length), 0, 0,
      ...frameBody];
    return [...ascii.encode('ID3'), 4, 0, 0, ..._syncSafe(frame.length),
      ...frame];
  }

  static List<int> _syncSafe(int size) => [
        (size >> 21) & 0x7F,
        (size >> 14) & 0x7F,
        (size >> 7) & 0x7F,
        size & 0x7F,
      ];

  /// The first [count] ADTS frames of [stream]: the encoder adds a flush
  /// frame past the 94 asked for, which would make segments overlap.
  static Uint8List _firstAdtsFrames(Uint8List stream, int count) {
    var offset = 0;
    for (var frame = 0; frame < count; frame++) {
      final length = ((stream[offset + 3] & 0x03) << 11) |
          (stream[offset + 4] << 3) |
          (stream[offset + 5] >> 5);
      offset += length;
    }
    return Uint8List.sublistView(stream, 0, offset);
  }
}
