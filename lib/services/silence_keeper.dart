import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Loops inaudible audio on a second player so that iOS does not suspend
/// the app while the radio is silent.
///
/// When the radio buffers or reconnects, no audio comes out, and iOS
/// suspends a silent app in the background within ~30–60s, even with the
/// `audio` background mode. That freezes the Dart isolate and every
/// reconnect path with it, so the radio stays silent until the app is
/// opened again. While the keeper loops [source], iOS sees audio output
/// and keeps the app running.
///
/// [start] and [stop] follow the radio player's state events, which often
/// come close together, so the latest call wins: a [stop] that lands while
/// a [start] still loads the audio keeps it from playing.
class SilenceKeeper {
  SilenceKeeper({required this.log, Uri? source})
      : source = source ?? Uri.parse('asset:///assets/silence.m4a');

  /// Where the keeper's log lines go.
  final void Function(String message) log;

  /// The silent audio to loop.
  final Uri source;

  // Just above zero so that AVPlayer keeps pushing samples to the audio
  // session (muted or zero-amplitude output may be optimized out, which
  // defeats the purpose). 0.001 is below the audible threshold.
  static const _volume = 0.001;

  AudioPlayer? _player;
  // The one-time load of [source], shared by overlapping starts: a second
  // load would interrupt the first one in just_audio.
  Future<AudioPlayer>? _load;
  // Bumped by every start and stop. Once the audio is loaded, a start
  // plays it only if no newer call came meanwhile, and a failed start
  // resets the state only then, so it never undoes a newer call.
  int _generation = 0;
  bool _wanted = false;
  bool _disposed = false;

  /// Starts looping the silence, if it is not already.
  ///
  /// Completes once the audio is loaded and playing was requested. Never
  /// throws: a failure is logged, and the next start tries again.
  Future<void> start() async {
    if (_disposed) return;
    _wanted = true;
    final generation = ++_generation;
    try {
      final player = await _loaded();
      if (generation != _generation || player.playing) return;
      // Not awaited: just_audio's play() completes only once playback
      // pauses or stops, which for a loop means the next stop().
      unawaited(player.play().catchError((Object e) {
        log('silence keeper play failed: $e');
      }));
      log('silence keeper started — preventing iOS background suspension');
    } catch (e) {
      if (generation == _generation) _wanted = false;
      log('silence keeper start failed: $e');
    }
  }

  /// Stops the silence, or keeps a start that is still loading from
  /// playing it.
  void stop() {
    final player = _player;
    final playing = player?.playing ?? false;
    if (!_wanted && !playing) return;
    _wanted = false;
    _generation++;
    if (player != null && playing) {
      unawaited(player.stop().catchError((Object e) {
        log('silence keeper stop failed: $e');
      }));
    }
    log('silence keeper stopped');
  }

  /// Stops the silence for good and releases the player.
  Future<void> dispose() async {
    stop();
    _disposed = true;
    _generation++;
    _load = null;
    final player = _player;
    _player = null;
    if (player == null) return;
    try {
      await player.dispose();
    } catch (e) {
      log('silence keeper dispose failed: $e');
    }
  }

  Future<AudioPlayer> _loaded() {
    final pending = _load;
    if (pending != null) return pending;
    final load = _loadSource();
    _load = load;
    // Registered before any start awaits the load, so a failed load is
    // forgotten by the time that start handles the error.
    load.then<void>((_) {}, onError: (Object _) {
      if (identical(_load, load)) _load = null;
    });
    return load;
  }

  Future<AudioPlayer> _loadSource() async {
    final player = _player ??= AudioPlayer(handleInterruptions: false);
    await player.setAudioSource(AudioSource.uri(source));
    await player.setLoopMode(LoopMode.all);
    await player.setVolume(_volume);
    return player;
  }
}
