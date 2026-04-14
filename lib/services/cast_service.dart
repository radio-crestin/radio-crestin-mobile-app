import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:rxdart/rxdart.dart';

import '../types/Station.dart';
import '../utils.dart';
import 'analytics_service.dart';

class CastService {
  static const _tag = 'CastService';

  /// Custom receiver app ID — set this after registering at
  /// https://cast.google.com/publish/
  /// Using the Default Media Receiver until custom receiver is deployed.
  static const String _customReceiverAppId = 'CC1AD845';

  final BehaviorSubject<List<GoogleCastDevice>> devices =
      BehaviorSubject.seeded([]);
  final BehaviorSubject<bool> isCasting = BehaviorSubject.seeded(false);
  final BehaviorSubject<GoogleCastConnectState> connectionState =
      BehaviorSubject.seeded(GoogleCastConnectState.disconnected);

  StreamSubscription? _devicesSubscription;
  StreamSubscription? _sessionSubscription;
  StreamSubscription? _mediaStatusSubscription;

  bool _discoveryStarted = false;

  void _log(String message) {
    developer.log('$_tag: $message');
  }

  Future<void> initialize() async {
    _log('Initializing');
    try {
      // Configure Cast context with app ID
      if (Platform.isIOS) {
        await GoogleCastContext.instance.setSharedInstanceWithOptions(
          IOSGoogleCastOptions(
            GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(
              _customReceiverAppId,
            ),
            suspendSessionsWhenBackgrounded: false,
          ),
        );
      } else {
        await GoogleCastContext.instance.setSharedInstanceWithOptions(
          GoogleCastOptions(
            suspendSessionsWhenBackgrounded: false,
          ),
        );
      }

      _devicesSubscription = GoogleCastDiscoveryManager.instance.devicesStream
          .listen((deviceList) {
        devices.add(deviceList);
        _log('Discovered ${deviceList.length} device(s)');
      });

      _sessionSubscription = GoogleCastSessionManager
          .instance.currentSessionStream
          .listen((session) {
        final state =
            GoogleCastSessionManager.instance.connectionState;
        connectionState.add(state);
        isCasting.add(state == GoogleCastConnectState.connected);
        _log('Session state: $state');
      });

      startDiscovery();
    } catch (e) {
      _log('Initialize failed: $e');
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
    _log('Connecting to ${device.friendlyName}');
    try {
      await GoogleCastSessionManager.instance
          .startSessionWithDevice(device);
      AnalyticsService.instance.capture('cast_connected', {
        'device_name': device.friendlyName,
      });
      return true;
    } catch (e) {
      _log('Connect failed: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    _log('Disconnecting');
    try {
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
      AnalyticsService.instance.capture('cast_disconnected');
    } catch (e) {
      _log('Disconnect failed: $e');
    }
  }

  Future<void> castStation(Station station) async {
    if (!isCasting.value) return;

    final streamUrl =
        Utils.getStationStreamUrls(station.rawStationData).firstOrNull;
    if (streamUrl == null) {
      _log('No stream URL for station ${station.title}');
      return;
    }

    // Use HTTPS thumbnail URL (not file:// cached path) — cast devices fetch remotely
    final thumbnailUrl = station.rawStationData.thumbnail_url ?? '';
    final songThumbnailUrl =
        station.rawStationData.now_playing?.song?.thumbnail_url;

    final images = <GoogleCastImage>[];
    final artUrl = songThumbnailUrl ?? thumbnailUrl;
    if (artUrl.isNotEmpty) {
      images.add(GoogleCastImage(url: Uri.parse(artUrl)));
    }

    final subtitle = _buildSubtitle(station);

    final mediaInfo = GoogleCastMediaInformation(
      contentId: streamUrl,
      streamType: CastMediaStreamType.live,
      contentUrl: Uri.parse(streamUrl),
      contentType: _guessContentType(streamUrl),
      metadata: GoogleCastMusicMediaMetadata(
        title: station.title,
        albumName: 'Radio Creștin',
        artist: subtitle.isNotEmpty ? subtitle : station.title,
        images: images,
      ),
    );

    try {
      await GoogleCastRemoteMediaClient.instance.loadMedia(mediaInfo);
      AnalyticsService.instance.capture('cast_station', {
        'station_id': station.id,
        'station_slug': station.slug,
      });
      _log('Casting ${station.title}');
    } catch (e) {
      _log('castStation failed: $e');
    }
  }

  /// Update metadata on the cast device when the song changes
  /// without restarting the stream.
  Future<void> updateMetadata(Station station) async {
    if (!isCasting.value) return;
    // Reload the media to update metadata — Chromecast doesn't support
    // metadata-only updates for live streams.
    await castStation(station);
  }

  String _buildSubtitle(Station station) {
    final parts = <String>[];
    if (station.songTitle.isNotEmpty) parts.add(station.songTitle);
    if (station.songArtist.isNotEmpty) parts.add(station.songArtist);
    return parts.join(' — ');
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

  void dispose() {
    stopDiscovery();
    _devicesSubscription?.cancel();
    _sessionSubscription?.cancel();
    _mediaStatusSubscription?.cancel();
    devices.close();
    isCasting.close();
    connectionState.close();
  }
}
