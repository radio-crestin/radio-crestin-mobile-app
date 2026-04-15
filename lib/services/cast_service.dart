import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:rxdart/rxdart.dart';

import 'package:get_it/get_it.dart';

import '../appAudioHandler.dart';
import '../globals.dart' as globals;
import '../types/Station.dart';
import '../utils.dart';
import 'analytics_service.dart';

class CastService {
  static const _tag = 'CastService';

  /// Google's Default Media Receiver — handles HLS, metadata, artwork
  /// natively on all Cast devices (Chromecast, Google Home Mini, etc.).
  /// No custom receiver HTML needed. Shows station art + metadata.
  /// Custom receiver at cast.radiocrestin.ro (ED38209C) can be restored
  /// once the custom UI is properly tested.
  static const String _customReceiverAppId = 'CC1AD845';

  final BehaviorSubject<List<GoogleCastDevice>> devices =
      BehaviorSubject.seeded([]);
  final BehaviorSubject<bool> isCasting = BehaviorSubject.seeded(false);
  final BehaviorSubject<GoogleCastConnectState> connectionState =
      BehaviorSubject.seeded(GoogleCastConnectState.disconnected);

  StreamSubscription? _devicesSubscription;
  StreamSubscription? _sessionSubscription;

  bool _discoveryStarted = false;

  void _log(String message) {
    developer.log('$_tag: $message');
    // Also print to system console for easier debugging
    print('[$_tag] $message');
  }

  Future<void> initialize() async {
    _log('Initializing with appId=$_customReceiverAppId, platform=${Platform.operatingSystem}');
    try {
      // Configure Cast context with app ID — MUST happen before discovery
      if (Platform.isIOS) {
        _log('Setting up iOS Cast options...');
        await GoogleCastContext.instance.setSharedInstanceWithOptions(
          IOSGoogleCastOptions(
            GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(
              _customReceiverAppId,
            ),
            suspendSessionsWhenBackgrounded: false,
            disableDiscoveryAutostart: false,
            startDiscoveryAfterFirstTapOnCastButton: false,
          ),
        );
        _log('iOS Cast options set successfully');
      } else {
        _log('Setting up Android Cast options...');
        await GoogleCastContext.instance.setSharedInstanceWithOptions(
          GoogleCastOptionsAndroid(appId: _customReceiverAppId),
        );
        _log('Android Cast options set successfully');
      }

      _devicesSubscription = GoogleCastDiscoveryManager.instance.devicesStream
          .listen((deviceList) {
        devices.add(deviceList);
        _log('Devices updated: ${deviceList.length} device(s)${deviceList.isNotEmpty ? ': ${deviceList.map((d) => '${d.friendlyName} (${d.modelName})').join(', ')}' : ''}');
      }, onError: (e) {
        _log('Devices stream error: $e');
      });

      _sessionSubscription = GoogleCastSessionManager
          .instance.currentSessionStream
          .listen((session) {
        // Read state from the session object directly (more reliable than the getter)
        final state = session?.connectionState ?? GoogleCastConnectState.disconnected;
        connectionState.add(state);
        final wasCasting = isCasting.value;
        final nowCasting = state == GoogleCastConnectState.connected;
        isCasting.add(nowCasting);
        _log('Session changed: state=$state, wasCasting=$wasCasting, nowCasting=$nowCasting, session=${session?.runtimeType}');
      }, onError: (e) {
        _log('Session stream error: $e');
      });

      // Start discovery immediately
      startDiscovery();
    } catch (e, st) {
      _log('Initialize failed: $e\n$st');
    }
  }

  void startDiscovery() {
    if (_discoveryStarted) return;
    _discoveryStarted = true;
    try {
      GoogleCastDiscoveryManager.instance.startDiscovery();
      _log('Discovery started');
    } catch (e) {
      _discoveryStarted = false;
      _log('startDiscovery failed: $e');
    }
  }

  /// Restart discovery — useful when the user opens the device picker
  /// to force a fresh scan of the network.
  void restartDiscovery() {
    _log('Restarting discovery');
    if (_discoveryStarted) {
      try {
        GoogleCastDiscoveryManager.instance.stopDiscovery();
      } catch (_) {}
    }
    _discoveryStarted = false;
    startDiscovery();
  }

  void stopDiscovery() {
    if (!_discoveryStarted) return;
    _discoveryStarted = false;
    try {
      GoogleCastDiscoveryManager.instance.stopDiscovery();
      _log('Discovery stopped');
    } catch (e) {
      _log('stopDiscovery failed: $e');
    }
  }

  Future<bool> connectToDevice(GoogleCastDevice device) async {
    _log('Connecting to ${device.friendlyName} (model: ${device.modelName})');
    try {
      await GoogleCastSessionManager.instance
          .startSessionWithDevice(device);
      _log('Connect request sent to ${device.friendlyName}');
      AnalyticsService.instance.capture('cast_connected', {
        'device_name': device.friendlyName,
      });
      return true;
    } catch (e, st) {
      _log('Connect failed: $e\n$st');
      return false;
    }
  }

  Future<void> disconnect() async {
    _log('Disconnecting');
    try {
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
      _log('Disconnected successfully');
      AnalyticsService.instance.capture('cast_disconnected');
    } catch (e) {
      _log('Disconnect failed: $e');
    }
  }

  Future<void> play() async {
    if (!isCasting.value) return;
    _log('play on Cast');
    try {
      await GoogleCastRemoteMediaClient.instance.play();
    } catch (e) {
      _log('play failed: $e');
    }
  }

  Future<void> pause() async {
    if (!isCasting.value) return;
    _log('pause on Cast');
    try {
      await GoogleCastRemoteMediaClient.instance.pause();
    } catch (e) {
      _log('pause failed: $e');
    }
  }

  Future<void> stop() async {
    if (!isCasting.value) return;
    _log('stop on Cast');
    try {
      await GoogleCastRemoteMediaClient.instance.stop();
    } catch (e) {
      _log('stop failed: $e');
    }
  }

  Future<void> castStation(Station station) async {
    _log('castStation called: station=${station.title}, isCasting=${isCasting.value}');
    if (!isCasting.value) {
      _log('castStation: not casting, skipping');
      return;
    }

    // Prefer non-HLS stream for Cast (more compatible with Google Home Mini)
    final streamUrl = _pickCastStreamUrl(station);
    if (streamUrl == null) {
      _log('castStation: no stream URL for station ${station.title}');
      return;
    }

    // Convert CDN image URLs: WebP → JPEG, 250px → 480px for Cast devices
    final thumbnailUrl = station.rawStationData.thumbnail_url ?? '';
    final songThumbnailUrl =
        station.rawStationData.now_playing?.song?.thumbnail_url;

    final images = <GoogleCastImage>[];
    final artUrl = _castImageUrl(songThumbnailUrl ?? thumbnailUrl);
    if (artUrl.isNotEmpty) {
      images.add(GoogleCastImage(url: Uri.parse(artUrl)));
    }

    final subtitle = _buildSubtitle(station);
    final contentType = _guessContentType(streamUrl);
    final trackedUrl = _addCastTrackingParams(streamUrl);

    _log('castStation: streamUrl=$trackedUrl, contentType=$contentType, '
        'title=${station.title}, artist=${subtitle.isNotEmpty ? subtitle : station.title}, '
        'artUrl=$artUrl, images=${images.length}');

    final mediaInfo = GoogleCastMediaInformation(
      contentId: trackedUrl,
      streamType: CastMediaStreamType.live,
      contentUrl: Uri.parse(trackedUrl),
      contentType: contentType,
      metadata: GoogleCastMusicMediaMetadata(
        title: station.title,
        albumName: 'Radio Creștin',
        artist: subtitle.isNotEmpty ? subtitle : station.title,
        images: images,
      ),
    );

    // Build recent songs for the current station for the receiver UI
    final recentSongs = _buildRecentSongs(station);

    _log('castStation: calling loadMedia...');
    try {
      await GoogleCastRemoteMediaClient.instance.loadMedia(
        mediaInfo,
        customData: {
          'recentSongs': recentSongs,
        },
      );
      _log('castStation: loadMedia completed for ${station.title}');
      AnalyticsService.instance.capture('cast_station', {
        'station_id': station.id,
        'station_slug': station.slug,
      });
    } catch (e, st) {
      _log('castStation: loadMedia FAILED: $e\n$st');
    }
  }

  String _buildSubtitle(Station station) {
    final parts = <String>[];
    if (station.songTitle.isNotEmpty) parts.add(station.songTitle);
    if (station.songArtist.isNotEmpty) parts.add(station.songArtist);
    return parts.join(' — ');
  }

  /// Builds a list of recent songs from the queue (populated by
  /// _updateSongHistoryQueue from the API). Each queue item has
  /// title=songName, artist="HH:MM - ArtistName", artUri=thumbnail.
  List<Map<String, dynamic>> _buildRecentSongs(Station currentStation) {
    try {
      final audioHandler = GetIt.instance<AppAudioHandler>();
      final queueItems = audioHandler.queue.value;

      return queueItems.take(5).map((item) {
        // artist field is "HH:MM - ArtistName" — extract the time part
        final artistParts = item.artist?.split(' - ') ?? [];
        final time = artistParts.isNotEmpty ? artistParts[0] : '';
        final artist = artistParts.length > 1 ? artistParts.sublist(1).join(' - ') : '';

        return <String, dynamic>{
          'title': item.title,
          'artist': artist,
          'time': time,
          'thumbnail': _castImageUrl(item.artUri?.toString() ?? ''),
        };
      }).toList();
    } catch (e) {
      _log('_buildRecentSongs failed: $e');
      return [];
    }
  }

  /// Pick a stream URL for Cast — excludes HLS completely.
  /// The Google Default Media Receiver has broken HLS live stream
  /// handling (relative URL resolution, intermittent disconnects).
  /// Direct streams (MP3/AAC) work reliably on all Cast devices.
  String? _pickCastStreamUrl(Station station) {
    final streams = Utils.getStationStreamObjects(station.rawStationData);
    if (streams.isEmpty) return null;

    for (final s in streams) {
      if (s['type'] != 'HLS') return s['url'];
    }
    _log('No non-HLS stream for ${station.title}, station cannot be cast');
    return null;
  }

  /// Convert a CDN image URL from WebP to JPEG and increase size for Cast.
  /// CDN format: https://cdn.radiocrestin.ro/?url=...&w=250&f=webp&max_age=...
  /// Cast needs: JPEG format, 480px width for TV display.
  String _castImageUrl(String url) {
    if (url.isEmpty) return url;
    if (!url.contains('cdn.radiocrestin.ro')) return url;

    // Replace WebP with JPEG and increase width to 480
    var castUrl = url
        .replaceAll('&f=webp', '&f=jpeg')
        .replaceAll('&f=avif', '&f=jpeg')
        .replaceAll('&w=250', '&w=480')
        .replaceAll('&w=100', '&w=480');

    // If no format was specified, add JPEG
    if (!castUrl.contains('&f=')) {
      castUrl += '&f=jpeg';
    }
    // If no width was specified, add 480
    if (!castUrl.contains('&w=')) {
      castUrl += '&w=480';
    }

    return castUrl;
  }

  String _guessContentType(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8') || lower.contains('hls')) {
      return 'application/x-mpegURL';
    }
    if (lower.contains('.aac')) return 'audio/aac';
    if (lower.contains('.ogg')) return 'audio/ogg';
    return 'audio/mpeg';
  }

  /// Adds tracking parameters to the Cast stream URL.
  /// The sender platform (ios/android) is included so we can distinguish
  /// which device initiated the Cast session.
  String _addCastTrackingParams(String url) {
    final senderPlatform = Platform.isIOS ? 'ios' : 'android';
    final uri = Uri.parse(url);
    final queryParams = Map<String, String>.from(uri.queryParameters);
    queryParams['ref'] = 'radio-crestin-chromecast-$senderPlatform';
    queryParams['s'] = globals.deviceId;
    return uri.replace(queryParameters: queryParams).toString();
  }

  void dispose() {
    stopDiscovery();
    _devicesSubscription?.cancel();
    _sessionSubscription?.cancel();
    devices.close();
    isCasting.close();
    connectionState.close();
  }
}
