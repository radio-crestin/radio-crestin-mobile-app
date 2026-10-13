import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:rxdart/rxdart.dart';

import 'analytics_service.dart';

/// Whether the device reaches the internet, and if not, why.
enum ConnectionStatus {
  /// On a network, and the internet answers.
  online,

  /// No network at all: airplane mode, WiFi and mobile data off.
  offline,

  /// On a network that does not reach the internet: a router without an
  /// uplink, a hotel WiFi before its login page.
  noInternet,
}

/// How `connectivity_plus` results map to the app's network state.
///
/// The plugin only reports the network interfaces, never whether the
/// internet answers through them — that takes [InternetProbe]s.
abstract final class ConnectivityPolicy {
  /// No network: only `none`, or nothing at all (an iOS transition).
  static bool hasNoNetwork(List<ConnectivityResult> results) {
    if (results.isEmpty) return true;
    return results.contains(ConnectivityResult.none) &&
        !results.contains(ConnectivityResult.mobile) &&
        !results.contains(ConnectivityResult.wifi) &&
        !results.contains(ConnectivityResult.ethernet);
  }

  /// On mobile data only: WiFi or ethernet, when present, carry the data.
  static bool isOnMobileData(List<ConnectivityResult> results) =>
      results.contains(ConnectivityResult.mobile) &&
      !results.contains(ConnectivityResult.wifi) &&
      !results.contains(ConnectivityResult.ethernet);
}

/// An endpoint that answers only when the internet is reachable.
class InternetProbe {
  const InternetProbe(this.url, this.answered);

  final Uri url;

  /// Whether [response] is the endpoint's own answer, not a stand-in.
  final bool Function(http.Response response) answered;

  /// What Android itself checks.
  static final google = InternetProbe(
    Uri.parse('https://connectivitycheck.gstatic.com/generate_204'),
    (response) => response.statusCode == 204,
  );

  /// What iOS itself checks.
  static final apple = InternetProbe(
    Uri.parse('https://captive.apple.com/hotspot-detect.html'),
    (response) =>
        response.statusCode == 200 && response.body.contains('Success'),
  );

  /// A second provider, in case the platform's own is blocked.
  static final cloudflare = InternetProbe(
    Uri.parse('https://cp.cloudflare.com/generate_204'),
    (response) => response.statusCode == 204,
  );

  /// The platform's own check, and Cloudflare.
  static List<InternetProbe> forPlatform() => [
        Platform.isIOS || Platform.isMacOS ? apple : google,
        cloudflare,
      ];
}

/// Tracks the network and whether the internet answers through it.
///
/// `connectivity_plus` says when a network comes and goes. A network can be
/// up without internet, though, so the probes confirm it: when a network
/// comes back, when a request of the app fails, and periodically while the
/// internet is out. A request of the app that gets an answer proves the
/// internet works.
class NetworkService {
  // Lazy-init so callers (including tests that don't bootstrap main()) always
  // get a usable instance. The seeded subjects (online, not on mobile data)
  // are safe defaults, and no probe runs until initialize() from main().
  static NetworkService get instance => _instance ??= NetworkService();
  static NetworkService? _instance;

  /// Creates the service and makes it [instance].
  ///
  /// The parameters exist for tests: the plugin, the HTTP client, the
  /// probes, their timeout, the recheck schedule (its last delay repeats)
  /// and the clock.
  NetworkService({
    Connectivity? connectivity,
    http.Client? httpClient,
    List<InternetProbe>? probes,
    Duration probeTimeout = const Duration(seconds: 4),
    List<Duration> recheckDelays = defaultRecheckDelays,
    DateTime Function()? clock,
  })  : _connectivity = connectivity ?? Connectivity(),
        _http = httpClient ??
            IOClient(HttpClient()..connectionTimeout = probeTimeout),
        _probes = probes ?? InternetProbe.forPlatform(),
        _probeTimeout = probeTimeout,
        _recheckDelays = recheckDelays,
        _now = clock ?? DateTime.now {
    _instance = this;
  }

  /// Waits between rechecks while the internet is out; the last repeats.
  ///
  /// Soon at first, as most outages on a live network are short (a router
  /// reboot, a DNS hiccup), then ever more rarely: a long outage should
  /// cost next to nothing. A request of the app that gets an answer ends
  /// the outage sooner anyway.
  static const defaultRecheckDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
  ];

  /// A failed request checks the internet at most this often while online:
  /// a station whose server is down keeps failing, and that is not news.
  static const _failureCheckInterval = Duration(seconds: 20);

  /// Spacing of the checks driven by network changes while not online: a
  /// network flapping between WiFi and mobile data would otherwise start a
  /// round of probes on every change. The last change still gets one.
  static const _networkChangeCheckSpacing = Duration(seconds: 1);

  /// How long an answered request (audio still arriving, say) vouches for
  /// the internet when the probes fail. On a weak signal the probes can
  /// time out while the stream plays: slow, not offline.
  static const _successVouchWindow = Duration(seconds: 10);

  final Connectivity _connectivity;
  final http.Client _http;
  final List<InternetProbe> _probes;
  final Duration _probeTimeout;
  final List<Duration> _recheckDelays;
  final DateTime Function() _now;

  StreamSubscription<List<ConnectivityResult>>? _subscription;

  final BehaviorSubject<bool> isOnMobileData = BehaviorSubject.seeded(false);

  /// Whether the internet is out of reach: no network, or a network
  /// without internet. [status] tells the two apart.
  final BehaviorSubject<bool> isOffline = BehaviorSubject.seeded(false);

  /// Whether the internet answers, and if not, why.
  final BehaviorSubject<ConnectionStatus> status =
      BehaviorSubject.seeded(ConnectionStatus.online);

  /// Whether anything needs the internet now. While it says no (app in the
  /// background, nothing playing), rechecks keep their pace but send no
  /// probes: nobody would see the answer, and the next request of the app
  /// gets one anyway. Set by the audio handler.
  bool Function() isInternetWanted = () => true;

  /// Probes run only once [initialize] starts monitoring, so tests that
  /// never call it make no real requests.
  bool _monitoring = false;
  bool _disposed = false;
  bool _hasNetwork = true;

  /// Bumped on every network change, so a check only ever speaks for the
  /// network it ran on.
  int _generation = 0;
  int _checkGeneration = -1;
  Future<bool>? _check;
  DateTime? _lastCheckAt;
  DateTime? _lastSuccessAt;
  int _lastSuccessGeneration = -1;
  DateTime? _lastFailureAt;
  DateTime? _lastNetworkChangeCheckAt;
  Timer? _networkChangeCheckTimer;
  Timer? _recheckTimer;
  int _recheckCount = 0;

  Future<void> initialize() async {
    _monitoring = true;
    try {
      final results = await _connectivity.checkConnectivity();
      _updateFromResults(results);
    } catch (e) {
      developer.log('NetworkService: initial check failed: $e');
    }
    if (_disposed) return;

    _subscription = _connectivity.onConnectivityChanged.listen((results) {
      _updateFromResults(results);
    });
  }

  /// Asks the probes whether the internet answers and updates [status].
  ///
  /// Concurrent callers on the same network share one check. Without a
  /// network, false at once.
  Future<bool> checkInternet() {
    if (_disposed || !_hasNetwork) return Future.value(false);
    if (!_monitoring) return Future.value(true);
    final pending = _check;
    if (pending != null && _checkGeneration == _generation) return pending;
    final check = _runCheck(_checkGeneration = _generation);
    _check = check;
    unawaited(check.whenComplete(() {
      if (identical(_check, check)) _check = null;
    }));
    return check;
  }

  /// A request of the app got an answer, or audio data arrived: the
  /// internet works. Cheap enough to call on every buffer update.
  void reportRequestSuccess() {
    if (_disposed) return;
    _lastSuccessAt = _now();
    _lastSuccessGeneration = _generation;
    // Also while back on a network whose probe is still out: the answer
    // came through it, whichever of the two arrives first.
    if (_hasNetwork && status.value != ConnectionStatus.online) {
      _setStatus(ConnectionStatus.online);
    }
  }

  /// A request of the app got no answer. While online, checks the internet
  /// still answers: a network can stay up while its internet goes.
  void reportRequestFailure() {
    if (_disposed) return;
    _lastFailureAt = _now();
    if (!_monitoring || status.value != ConnectionStatus.online) return;
    if (_checkedWithin(_failureCheckInterval)) return;
    unawaited(checkInternet());
  }

  void _updateFromResults(List<ConnectivityResult> results) {
    if (_disposed) return;
    final noNetwork = ConnectivityPolicy.hasNoNetwork(results);
    // Without a network the type is unknown: keep the last one. A tunnel
    // on mobile data would otherwise read as "off mobile data" and send
    // the list after song art it cannot download.
    final onMobile = noNetwork
        ? isOnMobileData.value
        : ConnectivityPolicy.isOnMobileData(results);
    final changed =
        noNetwork != !_hasNetwork || onMobile != isOnMobileData.value;
    _hasNetwork = !noNetwork;
    _generation++;

    if (onMobile != isOnMobileData.value) {
      developer.log('NetworkService: isOnMobileData = $onMobile');
      isOnMobileData.add(onMobile);
    }
    if (noNetwork) {
      _setStatus(ConnectionStatus.offline);
    } else if (status.value != ConnectionStatus.online) {
      // Back on a network, or on another one while the last had no
      // internet: say online only once the internet answers through it.
      _checkAfterNetworkChange();
    }

    if (changed) {
      AnalyticsService.instance.logDebug('connectivity changed', {
        'offline': noNetwork,
        'on_mobile_data': onMobile,
        'types': results.map((r) => r.name).join(','),
      });
    }
  }

  /// Checks the internet through a network that just changed, at most
  /// once per [_networkChangeCheckSpacing]; while it keeps changing, once
  /// more when it settles.
  void _checkAfterNetworkChange() {
    _networkChangeCheckTimer?.cancel();
    if (!_within(_lastNetworkChangeCheckAt, _networkChangeCheckSpacing)) {
      _lastNetworkChangeCheckAt = _now();
      unawaited(checkInternet());
      return;
    }
    _networkChangeCheckTimer = Timer(_networkChangeCheckSpacing, () {
      if (_disposed || status.value == ConnectionStatus.online) return;
      _lastNetworkChangeCheckAt = _now();
      unawaited(checkInternet());
    });
  }

  Future<bool> _runCheck(int generation) async {
    final stopwatch = Stopwatch()..start();
    final answered = await _anyProbeAnswers();
    if (_disposed) return answered;
    if (generation != _generation) {
      // The network changed while the probes ran, so their answer is
      // about the previous one: ask again, through this one.
      return checkInternet();
    }
    _lastCheckAt = _now();
    // A recent success vouches for an online status: audio still arriving
    // on a weak signal whose probes time out is slow, not offline. Only a
    // success newer than the last failure, though: once requests fail, the
    // audio of a minute ago proves nothing. Never across an outage or a
    // switch either: the network now in use has to answer for itself.
    final lastSuccess = _lastSuccessAt;
    final lastFailure = _lastFailureAt;
    final vouched = !answered &&
        status.value == ConnectionStatus.online &&
        _lastSuccessGeneration == generation &&
        _within(lastSuccess, _successVouchWindow) &&
        (lastFailure == null || !lastSuccess!.isBefore(lastFailure));
    final reachable = answered || vouched;
    developer.log('NetworkService: internet check → $answered'
        '${vouched ? ' (data still arriving: online)' : ''} '
        'in ${stopwatch.elapsedMilliseconds}ms');
    // The network may have gone while the probes ran; that status stands.
    if (_hasNetwork) {
      _setStatus(
          reachable ? ConnectionStatus.online : ConnectionStatus.noInternet);
    }
    return reachable;
  }

  /// True as soon as one probe answers, false once all of them failed.
  ///
  /// The probes run in parallel: without internet none answers, and
  /// waiting for each in turn would multiply the timeout.
  Future<bool> _anyProbeAnswers() {
    if (_probes.isEmpty) return Future.value(true);
    final result = Completer<bool>();
    var pending = _probes.length;
    for (final probe in _probes) {
      _probe(probe).then((answered) {
        if (result.isCompleted) return;
        if (answered) {
          result.complete(true);
        } else if (--pending == 0) {
          result.complete(false);
        }
      });
    }
    return result.future;
  }

  Future<bool> _probe(InternetProbe probe) async {
    try {
      final request = http.AbortableRequest(
        'GET',
        probe.url,
        // Aborted, not just abandoned, at the timeout: an abandoned
        // request keeps its socket until the system gives up (minutes).
        abortTrigger: Future<void>.delayed(_probeTimeout),
      )
        // A captive portal answers with a redirect to its login page.
        ..followRedirects = false
        // A kept-alive connection may belong to the network just left,
        // where it would hang until the timeout.
        ..persistentConnection = false;
      final response = await _http
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_probeTimeout);
      return probe.answered(response);
    } catch (_) {
      return false;
    }
  }

  void _setStatus(ConnectionStatus next) {
    if (_disposed || next == status.value) return;
    developer.log('NetworkService: status = ${next.name}');
    status.add(next);
    final offline = next != ConnectionStatus.online;
    if (offline != isOffline.value) isOffline.add(offline);

    _recheckTimer?.cancel();
    _recheckCount = 0;
    if (next == ConnectionStatus.noInternet) _scheduleRecheck();
    if (next != ConnectionStatus.offline) {
      AnalyticsService.instance.logDebug('internet reachability changed', {
        'status': next.name,
      });
    }
  }

  /// Rechecks while the internet is out, on the recheck delays. One chain
  /// only: a newer one replaces it.
  void _scheduleRecheck() {
    _recheckTimer?.cancel();
    if (_disposed) return;
    final index = _recheckCount < _recheckDelays.length
        ? _recheckCount
        : _recheckDelays.length - 1;
    _recheckCount++;
    late final Timer timer;
    timer = _recheckTimer = Timer(_recheckDelays[index], () async {
      if (isInternetWanted()) await checkInternet();
      if (identical(_recheckTimer, timer) &&
          status.value == ConnectionStatus.noInternet) {
        _scheduleRecheck();
      }
    });
  }

  bool _checkedWithin(Duration window) => _within(_lastCheckAt, window);

  bool _within(DateTime? at, Duration window) =>
      at != null && _now().difference(at) < window;

  /// Stops monitoring for good; the subjects close.
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _recheckTimer?.cancel();
    _networkChangeCheckTimer?.cancel();
    _http.close();
    isOnMobileData.close();
    isOffline.close();
    status.close();
  }
}
