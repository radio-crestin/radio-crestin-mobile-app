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

  /// Custom receiver app ID registered at https://cast.google.com/publish/
  /// Receiver hosted at https://cast.radiocrestin.ro
  static const String _customReceiverAppId = 'ED38209C';

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
        final state = GoogleCastSessionManager.instance.connectionState;
        connectionState.add(state);
        final wasCasting = isCasting.value;
        final nowCasting = state == GoogleCastConnectState.connected;
        isCasting.add(nowCasting);
        _log('Session changed: state=$state, wasCasting=$wasCasting, nowCasting=$nowCasting, session=$session');
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

  Future<void> castStation(Station station) async {
    _log('castStation called: station=${station.title}, isCasting=${isCasting.value}');
    if (!isCasting.value) {
      _log('castStation: not casting, skipping');
      return;
    }

    final streamUrl =
        Utils.getStationStreamUrls(station.rawStationData).firstOrNull;
    if (streamUrl == null) {
      _log('castStation: no stream URL for station ${station.title}');
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
    final contentType = _guessContentType(streamUrl);

    _log('castStation: streamUrl=$streamUrl, contentType=$contentType, '
        'title=${station.title}, artist=${subtitle.isNotEmpty ? subtitle : station.title}, '
        'artUrl=$artUrl, images=${images.length}');

    final mediaInfo = GoogleCastMediaInformation(
      contentId: streamUrl,
      streamType: CastMediaStreamType.live,
      contentUrl: Uri.parse(streamUrl),
      contentType: contentType,
      metadata: GoogleCastMusicMediaMetadata(
        title: station.title,
        albumName: 'Radio Creștin',
        artist: subtitle.isNotEmpty ? subtitle : station.title,
        images: images,
      ),
    );

    _log('castStation: calling loadMedia...');
    try {
      await GoogleCastRemoteMediaClient.instance.loadMedia(mediaInfo);
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
    devices.close();
    isCasting.close();
    connectionState.close();
  }
}
