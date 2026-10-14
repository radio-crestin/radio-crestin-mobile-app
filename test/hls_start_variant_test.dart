import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/hls_start_variant.dart';

void main() {
  const twoMinutes = Duration(minutes: 2);
  const fiveMinutes = Duration(minutes: 5);
  const hls = 'https://hls.radiocrestin.ro/hls/rve-suceava/index.m3u8';
  const live = 'https://live.radiocrestin.ro/hls/rve-suceava/index.m3u8';

  group('HlsStartVariant.urlFor', () {
    test('2 and 5 minutes map to index-2m.m3u8 and index-5m.m3u8', () {
      expect(HlsStartVariant.urlFor(hls, twoMinutes),
          'https://hls.radiocrestin.ro/hls/rve-suceava/index-2m.m3u8');
      expect(HlsStartVariant.urlFor(hls, fiveMinutes),
          'https://hls.radiocrestin.ro/hls/rve-suceava/index-5m.m3u8');
    });

    test('on live.radiocrestin.ro too', () {
      expect(HlsStartVariant.urlFor(live, twoMinutes),
          'https://live.radiocrestin.ro/hls/rve-suceava/index-2m.m3u8');
      expect(HlsStartVariant.urlFor(live, fiveMinutes),
          'https://live.radiocrestin.ro/hls/rve-suceava/index-5m.m3u8');
    });

    test('the /aac/ playlist gets the /aac/ variant', () {
      expect(
        HlsStartVariant.urlFor(
            'https://hls.radiocrestin.ro/hls/rve/aac/index.m3u8', fiveMinutes),
        'https://hls.radiocrestin.ro/hls/rve/aac/index-5m.m3u8',
      );
    });

    test('the host is matched whatever its case', () {
      expect(
        HlsStartVariant.urlFor(
            'https://HLS.RadioCrestin.ro/hls/rve/index.m3u8', twoMinutes),
        'https://hls.radiocrestin.ro/hls/rve/index-2m.m3u8',
      );
    });

    test('instant mode and any other offset: none', () {
      for (final offset in const [
        Duration.zero,
        Duration(minutes: 1),
        Duration(minutes: 4),
        Duration(minutes: 2, seconds: 1),
        Duration(seconds: 299),
        Duration(minutes: 10),
      ]) {
        expect(HlsStartVariant.urlFor(hls, offset), isNull, reason: '$offset');
      }
    });

    test('other hosts: none', () {
      for (final url in const [
        'https://hls.example.com/hls/rve/index.m3u8',
        'https://radiocrestin.ro/hls/rve/index.m3u8',
        'https://www.radiocrestin.ro/hls/rve/index.m3u8',
        'https://hls.radiocrestin.ro.example.com/hls/rve/index.m3u8',
        'https://evilhls.radiocrestin.ro/hls/rve/index.m3u8',
        'https://cdn.example.com/hls.radiocrestin.ro/index.m3u8',
      ]) {
        expect(HlsStartVariant.urlFor(url, twoMinutes), isNull, reason: url);
      }
    });

    test('playlists other than index.m3u8 and other streams: none', () {
      for (final url in const [
        'https://hls.radiocrestin.ro/hls/rve/dvr.m3u8',
        'https://hls.radiocrestin.ro/hls/rve/master.m3u8',
        'https://hls.radiocrestin.ro/hls/rve/index-2m.m3u8',
        'https://hls.radiocrestin.ro/hls/rve/myindex.m3u8',
        'https://hls.radiocrestin.ro/hls/rve/index.m3u8/x',
        'https://hls.radiocrestin.ro/hls/rve/stream.mp3',
        'https://hls.radiocrestin.ro/hls/rve/',
        'https://hls.radiocrestin.ro/hls/rve/index.m3u8x',
      ]) {
        expect(HlsStartVariant.urlFor(url, twoMinutes), isNull, reason: url);
      }
    });

    test('not a URL: none', () {
      expect(HlsStartVariant.urlFor('http://[::1', twoMinutes), isNull);
      expect(HlsStartVariant.urlFor('', twoMinutes), isNull);
    });

    test('keeps the query parameters (and their order)', () {
      expect(
        HlsStartVariant.urlFor('$hls?token=a%20b&x=1&ref=old', twoMinutes),
        'https://hls.radiocrestin.ro/hls/rve-suceava/index-2m.m3u8'
        '?token=a%20b&x=1&ref=old',
      );
    });

    test('the tracking parameters go on the variant like on index.m3u8', () {
      final variant = HlsStartVariant.urlFor('$hls?token=t', fiveMinutes)!;
      final tracked = Uri.parse(AppAudioHandler.withTrackingParameters(
        variant,
        source: 'ios',
        deviceId: 'device-1',
      ));

      expect(tracked.path, '/hls/rve-suceava/index-5m.m3u8');
      expect(tracked.queryParameters, {
        'token': 't',
        'ref': 'radio-crestin-ios',
        's': 'device-1',
      });
    });
  });

  group('HlsStartVariant.mayBeMissing', () {
    final timeout = TimeoutException('load', const Duration(seconds: 3));
    final exoSourceError = PlayerException(0, 'Source error', null);

    test(
        'an HTTP error status (AVPlayer\'s 404 included) falls back on '
        'every platform, even with the internet flagged out: the origin '
        'answered', () {
      for (final error in [
        PlayerException(404, 'Not Found', null),
        PlayerException(-1100, 'file does not exist', null),
        PlayerException(503, 'unavailable', null),
      ]) {
        for (final android in [false, true]) {
          for (final offline in [false, true]) {
            expect(
              HlsStartVariant.mayBeMissing(error,
                  httpStatus: true, android: android, offline: offline),
              isTrue,
              reason: '${error.code} android=$android offline=$offline',
            );
          }
        }
      }
    });

    test('Darwin: a timeout or any other error is the stream\'s, as before',
        () {
      for (final error in [
        timeout,
        exoSourceError,
        PlayerException(-1009, 'offline', null),
      ]) {
        expect(
          HlsStartVariant.mayBeMissing(error,
              httpStatus: false, android: false, offline: false),
          isFalse,
          reason: '$error',
        );
      }
    });

    test(
        'Android: ExoPlayer\'s 404 (a load timeout, or a type-0 source '
        'error) falls back', () {
      for (final error in [timeout, exoSourceError]) {
        expect(
          HlsStartVariant.mayBeMissing(error,
              httpStatus: false, android: true, offline: false),
          isTrue,
          reason: '$error',
        );
      }
    });

    test(
        'Android without internet: the same errors are the network\'s, '
        'no fallback that would only time out again', () {
      for (final error in [timeout, exoSourceError]) {
        expect(
          HlsStartVariant.mayBeMissing(error,
              httpStatus: false, android: true, offline: true),
          isFalse,
          reason: '$error',
        );
      }
    });

    test('a cancelled or interrupted load never falls back', () {
      for (final error in [
        'cancelled',
        PlayerInterruptedException('Loading interrupted'),
      ]) {
        for (final android in [false, true]) {
          expect(
            HlsStartVariant.mayBeMissing(error,
                httpStatus: false, android: android, offline: false),
            isFalse,
            reason: '$error android=$android',
          );
        }
      }
    });
  });

  group('HlsStartVariant.followUp', () {
    HlsStartFollowUp followUp(
      Duration? variant,
      Duration current, {
      bool restart = false,
    }) =>
        HlsStartVariant.followUp(
          variantOffset: variant,
          currentOffset: current,
          seekRestartsPlayback: restart,
        );

    test('the stream\'s own playlist: the seek, as before', () {
      for (final current in const [Duration.zero, twoMinutes, fiveMinutes]) {
        for (final restart in [false, true]) {
          expect(
              followUp(null, current, restart: restart), HlsStartFollowUp.seek,
              reason: '$current restart=$restart');
        }
      }
    });

    test('a variant for the listening offset: nothing, it starts there', () {
      expect(followUp(twoMinutes, twoMinutes), HlsStartFollowUp.none);
      expect(followUp(fiveMinutes, fiveMinutes), HlsStartFollowUp.none);
    });

    test('a variant reloaded while playing on Darwin: the seek restarts it',
        () {
      expect(followUp(twoMinutes, twoMinutes, restart: true),
          HlsStartFollowUp.seek);
    });

    test('the offset changed while the variant loaded: the seek to it', () {
      for (final restart in [false, true]) {
        expect(followUp(twoMinutes, fiveMinutes, restart: restart),
            HlsStartFollowUp.seek);
        expect(followUp(fiveMinutes, twoMinutes, restart: restart),
            HlsStartFollowUp.seek);
      }
    });

    test(
        'instant mode came on while the variant loaded: a reload, as no '
        'seek starts at the live point', () {
      for (final restart in [false, true]) {
        expect(followUp(twoMinutes, Duration.zero, restart: restart),
            HlsStartFollowUp.reload);
      }
    });
  });
}
