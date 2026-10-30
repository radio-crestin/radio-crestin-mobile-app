import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// An action chosen from the macOS menu bar or Dock menu, or by a desktop
/// keyboard shortcut.
enum DesktopCommand {
  playPause,
  next,
  previous,
  toggleFavorite,
  search,
  settings,
  nowPlaying,

  /// Back and forward, as in a browser: the mouse's side buttons, or ⌘[
  /// and ⌘].
  back,
  forward,

  /// The volume a step up or down: ⌘↑ and ⌘↓, as in Apple Music.
  volumeUp,
  volumeDown,

  /// Mutes or unmutes: M.
  toggleMute,
}

/// Where the macOS window's own buttons (close, minimize, zoom) sit over
/// the desktop shell's top bar, which runs under the window's transparent
/// title bar: the bar makes room for them and is as tall as centers it on
/// them.
@immutable
class DesktopTitleBar {
  const DesktopTitleBar({this.height = defaultHeight, this.leading = 0});

  /// What the window says, as `{height, leading}`; 0 or missing values
  /// for buttons that are hidden, as in full screen.
  factory DesktopTitleBar.fromMap(Object? map) {
    if (map is! Map) return const DesktopTitleBar();
    double read(String key) => (map[key] as num?)?.toDouble() ?? 0;
    final height = read('height');
    return DesktopTitleBar(
      // A height the bar's content can't fit in, or that leaves the bar too
      // tall, is ignored.
      height: height >= minHeight && height <= maxHeight
          ? height
          : defaultHeight,
      leading: read('leading'),
    );
  }

  /// The bar's height when the window says nothing: macOS centers its
  /// buttons 26 points down, in a unified toolbar.
  static const double defaultHeight = 52;
  static const double minHeight = 44;
  static const double maxHeight = 72;

  /// The top bar's height, with the window buttons centered in it.
  final double height;

  /// Where the window buttons end, from the window's start; 0 when there
  /// are none on the bar.
  final double leading;

  /// Whether the window's buttons show over the top bar.
  bool get hasWindowButtons => leading > 0;

  @override
  bool operator ==(Object other) =>
      other is DesktopTitleBar &&
      other.height == height &&
      other.leading == leading;

  @override
  int get hashCode => Object.hash(height, leading);
}

/// Connects the macOS menu bar and Dock menu to the desktop shell.
///
/// The native side (`macos/Runner/DesktopMenuChannel.swift`; the menu actions
/// and Dock menu are in `macos/Runner/AppDelegate.swift`) calls `command` on
/// [channelName] with a [DesktopCommand] name. The shell's own keyboard
/// shortcuts go through [dispatch] as well, so a menu item and its shortcut
/// always do the same thing. The shell reports what is playing through
/// [updateState], so the menus can say "Pauză" or "Redă" and disable
/// what has no station to act on, and brings back a closed window with
/// [showWindow]. The window tells where its buttons sit over the top bar
/// ([titleBar]).
class DesktopMenuService {
  DesktopMenuService._();

  static const channelName = 'com.radiocrestin.desktop_menu';
  static const _channel = MethodChannel(channelName);
  static final _commands = StreamController<DesktopCommand>.broadcast();
  static final _stationRequests = StreamController<String>.broadcast();

  /// The commands, in the order they were chosen.
  static Stream<DesktopCommand> get commands => _commands.stream;

  /// The slugs of the stations chosen under "Ascultate recent" in the Dock
  /// menu, to play.
  static Stream<String> get stationRequests => _stationRequests.stream;

  static bool get _isMacOS => !kIsWeb && Platform.isMacOS;

  /// Where the window's buttons sit over the top bar; it follows the window
  /// into and out of full screen. No buttons off macOS.
  static final ValueNotifier<DesktopTitleBar> titleBar =
      ValueNotifier(const DesktopTitleBar());

  /// Starts taking commands from the native menus, and tells the window
  /// when the first frame is on screen, by when its title bar is laid out;
  /// a no-op off macOS.
  static void initialize() {
    if (!_isMacOS) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'command':
          final command = DesktopCommand.values.asNameMap()[call.arguments];
          if (command != null) dispatch(command);
        case 'playStation':
          if (call.arguments case final String slug) {
            _stationRequests.add(slug);
          }
        case 'titleBar':
          titleBar.value = DesktopTitleBar.fromMap(call.arguments);
      }
    });
    unawaited(_fetchTitleBar());
    unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized
        .then((_) => _invoke('ready')));
  }

  /// Asks the window where its buttons sit, before the first frame.
  static Future<void> _fetchTitleBar() async {
    try {
      final geometry = await _channel.invokeMethod<Object?>('titleBar');
      if (geometry != null) {
        titleBar.value = DesktopTitleBar.fromMap(geometry);
      }
    } on MissingPluginException {
      // An older native shell: a bar with no window buttons on it.
    } on PlatformException catch (e) {
      debugPrint('DesktopMenuService: titleBar failed: $e');
    }
  }

  /// Hands [command] to the shell, as choosing it from a menu does.
  static void dispatch(DesktopCommand command) => _commands.add(command);

  /// Tells the native menus what is playing, and which stations the Dock
  /// menu offers under "Ascultate recent" ([recent], newest first).
  ///
  /// [hasStation] is false before any station was picked, when the playback
  /// items have nothing to act on. [muted]: whether the volume is at 0, for
  /// the mute item to offer turning the sound back on.
  static Future<void> updateState({
    required bool hasStation,
    required bool playing,
    required bool isFavorite,
    bool muted = false,
    List<({String slug, String title})> recent = const [],
  }) =>
      _invoke('state', {
        'hasStation': hasStation,
        'playing': playing,
        'isFavorite': isFavorite,
        'muted': muted,
        'recent': [
          for (final station in recent)
            {'slug': station.slug, 'title': station.title},
        ],
      });

  /// Shows the window, closed or minimized, as a click on the Dock icon
  /// does.
  ///
  /// Closing the window leaves the app running, and a link that opens a
  /// station brings the app forward without its window.
  static Future<void> showWindow() => _invoke('show');

  /// Tells the window whether the pointer rests on an empty part of the top
  /// bar, where a press moves the window (see `DesktopWindowDragArea`).
  static Future<void> setOverWindowDragArea(bool over) =>
      _invoke('dragArea', over);

  static Future<void> _invoke(String method, [Object? arguments]) async {
    if (!_isMacOS) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // The menus are not set up (a test, or an older native shell).
    } on PlatformException catch (e) {
      debugPrint('DesktopMenuService: $method failed: $e');
    }
  }
}
