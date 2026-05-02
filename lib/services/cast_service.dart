import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:rxdart/rxdart.dart';

import 'package:get_it/get_it.dart';

import '../globals.dart' as globals;
import '../types/Station.dart';
import '../utils.dart';
import 'analytics_service.dart';

class CastService {
  static const _tag = 'CastService';

  /// Google Default Media Receiver — native UI with artwork, metadata,
  /// and playback controls on all Cast devices.
  static const String _customReceiverAppId = 'CC1AD845';

  final BehaviorSubject<List<GoogleCastDevice>> devices =
      BehaviorSubject.seeded([]);
  final BehaviorSubject<bool> isCasting = BehaviorSubject.seeded(false);
  final BehaviorSubject<GoogleCastConnectState> connectionState =
      BehaviorSubject.seeded(GoogleCastConnectState.disconnected);

  /// Cast player state streamed from the receiver via mediaStatusStream.
  final BehaviorSubject<CastMediaPlayerState> castPlayerState =
      BehaviorSubject.seeded(CastMediaPlayerState.unknown);

  /// Friendly name of the currently connected Cast device (e.g. "Living Room TV").
  final BehaviorSubject<String?> connectedDeviceName =
      BehaviorSubject.seeded(null);

  StreamSubscription? _devicesSubscription;
  StreamSubscription? _sessionSubscription;
  StreamSubscription? _mediaStatusSubscription;

  bool _discoveryStarted = false;

  /// Last station slug sent to Cast — prevents duplicate loadMedia calls
  /// when the station changes. Does NOT block metadata-only updates.
  String? lastCastSlug;

  /// The stream URL currently loaded on the Cast device. Used to re-load
  /// the same stream with updated metadata without picking a new URL.
  String? _lastCastStreamUrl;

  /// Type of the currently loaded Cast stream ('HLS' or 'direct_stream').
  /// Drives `contentType` and `hlsSegmentFormat` on metadata reloads.
  String? _lastCastStreamType;

  /// True when the current Cast session was started by another sender
  /// (another phone, another app) and this app is merely observing /
  /// controlling playback. While set, metadata refreshes are suppressed
  /// — replacing the media would clobber the other sender's session.
  /// Cleared automatically when we call `castStation()` (the user picked
  /// a station from this app, so we take ownership).
  bool _adoptedSession = false;

  bool get isSessionAdopted => _adoptedSession;

  /// Mark the currently connected Cast session as adopted — tells
  /// `updateCastMetadata` to no-op so we don't send a LOAD that would
  /// replace another sender's media.
  void markSessionAdopted() {
    _adoptedSession = true;
    _log('Session marked as adopted (external sender) — '
        'metadata pushes suppressed');
  }

  void _log(String message) {
    developer.log('$_tag: $message');
    // Also print to system console for easier debugging
    print('[$_tag] $message');
  }

  /// The Cast receiver's current MediaStatus, or `null` if no media is
  /// loaded / the session hasn't reported yet. Backed by a BehaviorSubject
  /// inside the plugin so it's synchronous after the first event arrives.
  GoggleCastMediaStatus? get currentMediaStatus =>
      GoogleCastRemoteMediaClient.instance.mediaStatus;

  /// Waits up to [timeout] for the Cast receiver to report a MediaStatus
  /// with non-empty `mediaInformation.contentId`. Used when adopting an
  /// in-progress Cast session so we don't clobber another sender's media
  /// with our own LOAD before we've seen what's already playing.
  Future<GoggleCastMediaStatus?> waitForActiveMediaStatus({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    final existing = currentMediaStatus;
    if (_hasActiveMedia(existing)) return existing;
    try {
      return await GoogleCastRemoteMediaClient.instance.mediaStatusStream
          .firstWhere(_hasActiveMedia)
          .timeout(timeout);
    } catch (_) {
      return currentMediaStatus;
    }
  }

  bool _hasActiveMedia(GoggleCastMediaStatus? status) {
    final id = status?.mediaInformation?.contentId;
    return id != null && id.isNotEmpty;
  }

  /// Identifies which [Station] the Cast receiver is currently playing by
  /// matching its MediaInformation against each station's declared stream
  /// URLs. Query parameters (tracking refs etc.) are stripped before
  /// comparison — our app appends `?ref=...&s=...` and other senders may
  /// append different params, so only the bare URL is load-bearing.
  /// Returns `null` when nothing matches (another app is casting) or
  /// MediaStatus has no content yet.
  Station? matchStationFromCastMedia(
    List<Station> stations,
    GoggleCastMediaStatus? status,
  ) {
    final info = status?.mediaInformation;
    if (info == null) return null;
    final candidates = <String>[
      info.contentId,
      info.contentUrl?.toString() ?? '',
    ].where((s) => s.isNotEmpty).map(_stripQuery).toSet();
    if (candidates.isEmpty) return null;

    for (final station in stations) {
      final streams = Utils.getStationStreamObjects(station.rawStationData);
      for (final entry in streams) {
        final url = entry['url'] ?? '';
        if (url.isEmpty) continue;
        if (candidates.contains(_stripQuery(url))) return station;
      }
    }
    return null;
  }

  String _stripQuery(String url) {
    final idx = url.indexOf('?');
    return idx >= 0 ? url.substring(0, idx) : url;
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
            stopReceiverApplicationWhenEndingSession: true,
            stopCastingOnAppTerminated: true,
          ),
        );
        _log('iOS Cast options set successfully');
      } else {
        _log('Setting up Android Cast options...');
        await GoogleCastContext.instance.setSharedInstanceWithOptions(
          GoogleCastOptionsAndroid(
            appId: _customReceiverAppId,
            stopCastingOnAppTerminated: true,
          ),
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
        connectedDeviceName.add(nowCasting ? session?.device?.friendlyName : null);
        if (!nowCasting) {
          castPlayerState.add(CastMediaPlayerState.unknown);
          _lastCastStreamUrl = null;
          _lastCastStreamType = null;
          _adoptedSession = false;
        }
        _log('Session changed: state=$state, wasCasting=$wasCasting, nowCasting=$nowCasting, device=${session?.device?.friendlyName}');
      }, onError: (e) {
        _log('Session stream error: $e');
      });

      // Subscribe to remote media status for real-time playback state sync
      _mediaStatusSubscription = GoogleCastRemoteMediaClient
          .instance.mediaStatusStream
          .listen((status) {
        if (status != null) {
          final prev = castPlayerState.value;
          castPlayerState.add(status.playerState);
          if (prev != status.playerState) {
            _log('Cast player state: $prev -> ${status.playerState}');
          }
        }
      }, onError: (e) {
        _log('Media status stream error: $e');
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
      // Stop playback on Cast device first, then end session
      try { await GoogleCastRemoteMediaClient.instance.stop(); } catch (_) {}
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
      lastCastSlug = null;
      _lastCastStreamUrl = null;
      _lastCastStreamType = null;
      _adoptedSession = false;
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

    final pick = _pickCastStream(station);
    if (pick == null) {
      _log('castStation: no stream URL for station ${station.title}');
      return;
    }

    // The user picked a station from this app — we own the session now.
    // Any prior "adopted" state ends here; metadata pushes resume.
    _adoptedSession = false;

    final trackedUrl = _addCastTrackingParams(pick.url);
    _lastCastStreamUrl = trackedUrl;
    _lastCastStreamType = pick.type;

    final mediaInfo = _buildMediaInfo(station, trackedUrl, pick.type);

    _log('castStation: loadMedia $trackedUrl (type=${pick.type})');
    try {
      await GoogleCastRemoteMediaClient.instance.loadMedia(mediaInfo);
      _log('castStation: loadMedia OK');
      AnalyticsService.instance.capture('cast_station', {
        'station_id': station.id,
        'station_slug': station.slug,
        'stream_type': pick.type,
      });
    } catch (e) {
      _log('castStation: loadMedia FAILED: $e');
    }
  }

  /// Push updated metadata (song title, artist, artwork) to the Cast
  /// device without changing the audio stream. Called when the station
  /// poll detects a new song while casting.
  Future<void> updateCastMetadata(Station station) async {
    if (!isCasting.value) return;
    if (_adoptedSession) {
      // Another sender owns this session — they're already pushing
      // metadata. Sending our own LOAD would replace their media.
      return;
    }
    final castUrl = _lastCastStreamUrl;
    final castType = _lastCastStreamType;
    if (castUrl == null || castType == null) {
      _log('updateCastMetadata: no active stream, falling back to full castStation');
      return castStation(station);
    }

    final mediaInfo = _buildMediaInfo(station, castUrl, castType);
    _log('updateCastMetadata: reloading with updated metadata for ${station.title}');
    try {
      await GoogleCastRemoteMediaClient.instance.loadMedia(mediaInfo);
      _log('updateCastMetadata: OK');
    } catch (e) {
      _log('updateCastMetadata: FAILED: $e');
    }
  }

  /// Builds a GoogleCastMediaInformation with current station metadata.
  /// [streamType] is the API-declared type — currently always a non-HLS
  /// direct stream because Google Home / Nest audio-only receivers don't
  /// implement an HLS playlist parser (LOAD hangs in LOADING indefinitely
  /// regardless of segment format).
  GoogleCastMediaInformation _buildMediaInfo(
      Station station, String trackedUrl, String streamType) {
    final thumbnailUrl = station.rawStationData.thumbnail_url ?? '';
    final songThumbnailUrl =
        station.rawStationData.now_playing?.song?.thumbnail_url;

    final images = <GoogleCastImage>[];
    final artUrl = _castImageUrl(songThumbnailUrl ?? thumbnailUrl);
    if (artUrl.isNotEmpty) {
      images.add(GoogleCastImage(url: Uri.parse(artUrl)));
    }

    final subtitle = _buildSubtitle(station);
    final contentType = _guessContentType(trackedUrl);

    _log('_buildMediaInfo: title=${station.title}, '
        'artist=${subtitle.isNotEmpty ? subtitle : station.title}, '
        'streamType=$streamType, contentType=$contentType, artUrl=$artUrl');

    return GoogleCastMediaInformation(
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
  }

  String _buildSubtitle(Station station) {
    final parts = <String>[];
    if (station.songTitle.isNotEmpty) parts.add(station.songTitle);
    if (station.songArtist.isNotEmpty) parts.add(station.songArtist);
    return parts.join(' — ');
  }

  /// Pick a stream for Cast. Skips HLS entirely (audio-only Google/Nest
  /// receivers hang on HLS LOAD) and returns the first non-HLS stream in
  /// API order. Returns null when the station has no non-HLS variant —
  /// those stations cannot be cast.
  ({String url, String type})? _pickCastStream(Station station) {
    final streams = Utils.getStationStreamObjects(station.rawStationData);
    if (streams.isEmpty) return null;

    for (final s in streams) {
      final type = s['type'];
      final url = s['url'];
      if (type != null && type != 'HLS' && (url?.isNotEmpty ?? false)) {
        return (url: url!, type: type);
      }
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
    _mediaStatusSubscription?.cancel();
    devices.close();
    isCasting.close();
    connectionState.close();
    castPlayerState.close();
    connectedDeviceName.close();
  }
}
