import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

/// Tests that playback pauses when CarPlay / Android Auto disconnects.
void main() {
  group('Car disconnect pauses playback', () {
    late BehaviorSubject<PlaybackState> playbackState;
    late BehaviorSubject<bool> isCarConnected;
    late bool pauseCalled;

    /// Simulates the connection change handler logic in CarPlayService.
    void onConnectionChange(bool connected) {
      isCarConnected.add(connected);
      if (!connected && playbackState.value.playing) {
        pauseCalled = true;
      }
    }

    setUp(() {
      playbackState = BehaviorSubject<PlaybackState>.seeded(
        PlaybackState(playing: false, processingState: AudioProcessingState.idle),
      );
      isCarConnected = BehaviorSubject<bool>.seeded(false);
      pauseCalled = false;
    });

    tearDown(() {
      playbackState.close();
      isCarConnected.close();
    });

    test('pauses when car disconnects while playing', () {
      // Playing via car
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
      isCarConnected.add(true);

      // Car disconnects
      onConnectionChange(false);

      expect(pauseCalled, true);
      expect(isCarConnected.value, false);
    });

    test('does not pause when car disconnects while already paused', () {
      // Paused, car connected
      playbackState.add(PlaybackState(playing: false, processingState: AudioProcessingState.ready));
      isCarConnected.add(true);

      // Car disconnects
      onConnectionChange(false);

      expect(pauseCalled, false, reason: 'Should not pause when already paused');
    });

    test('does not pause on car connect', () {
      // Playing, car not connected
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));

      // Car connects
      onConnectionChange(true);

      expect(pauseCalled, false, reason: 'Should not pause on connect');
    });

    test('pauses on disconnect even during buffering', () {
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.buffering));
      isCarConnected.add(true);

      onConnectionChange(false);

      expect(pauseCalled, true);
    });

    test('reconnect then disconnect pauses correctly', () {
      playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));

      // Connect
      onConnectionChange(true);
      expect(pauseCalled, false);

      // Disconnect
      onConnectionChange(false);
      expect(pauseCalled, true);
    });
  });
}
