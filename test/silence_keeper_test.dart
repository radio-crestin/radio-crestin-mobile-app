import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/silence_keeper.dart';

import 'helpers/fake_just_audio_channels.dart';

/// The iOS silence keeper, on a fake just_audio plugin whose play call
/// answers only once playback stops, as the native one does: a stop always
/// silences the keeper, a start always gets it playing again, and an
/// awaited start returns.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const loadDelay = Duration(milliseconds: 50);
  const startLimit = Duration(seconds: 2);
  const audioSessionChannel = MethodChannel('com.ryanheise.audio_session');
  final source = Uri.parse('https://silence.test/silence.m4a');

  late FakeJustAudioChannels channels;
  late List<String> logs;
  late SilenceKeeper keeper;

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    channels = FakeJustAudioChannels()
      ..holdPlayUntilStopped = true
      ..install();
    // just_audio's play() activates the audio session first. Answered
    // here, that stays in the test's event queue instead of waiting on
    // the engine, so settle() is enough for the play call to arrive.
    messenger().setMockMethodCallHandler(audioSessionChannel, (_) async {
      return null;
    });
    logs = [];
    keeper = SilenceKeeper(log: logs.add, source: source);
  });

  tearDown(() async {
    await keeper.dispose();
    messenger().setMockMethodCallHandler(audioSessionChannel, null);
    channels.uninstall();
  });

  /// Lets the fake plugin answer every call in flight.
  Future<void> settle() => pumpEventQueue();

  /// Waits for the load in flight to finish, then for what follows it.
  Future<void> outlastLoad() async {
    await Future<void>.delayed(loadDelay * 2);
    await settle();
  }

  test('an awaited start returns once the silence plays', () async {
    await keeper.start().timeout(startLimit);
    await settle();

    expect(channels.isAnyPlayerPlaying, isTrue);
  });

  test('a stop silences a started keeper', () async {
    unawaited(keeper.start());
    await settle();
    expect(channels.isAnyPlayerPlaying, isTrue);

    keeper.stop();
    await settle();

    expect(channels.isAnyPlayerPlaying, isFalse);
  });

  test('start, start, stop, start: the silence plays again', () async {
    // A stall starts it, a failed reconnect attempt starts it again, audio
    // comes back, then the next outage starts it once more.
    unawaited(keeper.start());
    await settle();
    unawaited(keeper.start());
    await settle();
    keeper.stop();
    await settle();
    expect(channels.isAnyPlayerPlaying, isFalse);

    unawaited(keeper.start());
    await settle();

    expect(channels.isAnyPlayerPlaying, isTrue);
  });

  test('a stop during the load keeps the silence from playing', () async {
    final load = channels.loadGate = Completer<void>();
    final starting = keeper.start();
    await settle();
    expect(channels.loads, hasLength(1), reason: 'the load is in flight');

    keeper.stop();
    load.complete();
    await starting.timeout(startLimit);
    await settle();

    expect(channels.isAnyPlayerPlaying, isFalse);
  });

  test('overlapping starts load the audio once and both return', () async {
    channels.loadDelay = loadDelay;

    await Future.wait([keeper.start(), keeper.start()]).timeout(startLimit);
    await settle();

    expect(channels.loads, [source.toString()]);
    expect(channels.isAnyPlayerPlaying, isTrue);
  });

  test('a start after a stop during the load still plays', () async {
    final load = channels.loadGate = Completer<void>();
    final first = keeper.start();
    await settle();
    keeper.stop();
    final second = keeper.start();

    load.complete();
    await Future.wait([first, second]).timeout(startLimit);
    await settle();

    expect(channels.loads, hasLength(1));
    expect(channels.isAnyPlayerPlaying, isTrue);
  });

  test('a failed load lets the next start try again', () async {
    channels.failingUrlParts.add('silence');
    await keeper.start().timeout(startLimit);
    await settle();
    expect(channels.isAnyPlayerPlaying, isFalse);
    expect(logs, contains(startsWith('silence keeper start failed')));

    channels.failingUrlParts.clear();
    await keeper.start().timeout(startLimit);
    await settle();

    expect(channels.loads, hasLength(2));
    expect(channels.isAnyPlayerPlaying, isTrue);
  });

  test('dispose silences the keeper, and a start during it stays silent',
      () async {
    unawaited(keeper.start());
    await settle();
    expect(channels.isAnyPlayerPlaying, isTrue);

    final disposing = keeper.dispose();
    unawaited(keeper.start());
    await disposing;
    await outlastLoad();

    expect(channels.isAnyPlayerPlaying, isFalse);
  });
}
