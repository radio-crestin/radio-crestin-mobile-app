import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/video_playback_service.dart';

/// Regression guard for the engine-agnostic video buffering config.
///
/// The old libmpv tuning map (audio-buffer, demuxer caches, hwdec, reconnect
/// flags) is GONE — with the official `video_player` plugin, buffer sizing and
/// HTTP reconnection are owned by the native player (AVPlayer on iOS,
/// ExoPlayer/Media3 on Android) and are not configurable from Dart. The only
/// buffering constant that survives is [liveForwardBufferSeconds], kept purely
/// as the single enforced lock-step link to the radio (just_audio) pipeline's
/// forward-buffer target — the two live in libraries that must not import each
/// other, so this equality is the one thing keeping them from drifting apart.
void main() {
  group('live forward-buffer target', () {
    test('is 120s (2 minutes)', () {
      expect(VideoPlaybackService.liveForwardBufferSeconds, 120);
    });

    test('stays in lock-step with the radio pipeline\'s '
        'FastStartConfig.liveForwardBufferTarget', () {
      // The two constants live in libraries that must not import each other;
      // this equality is the single enforced link keeping radio + video in sync.
      expect(VideoPlaybackService.liveForwardBufferSeconds,
          FastStartConfig.liveForwardBufferTarget.inSeconds,
          reason: 'radio (just_audio) and video (video_player) live '
              'forward-buffer targets must not drift apart');
    });
  });
}
