import FlutterMacOS
import Foundation

/// An action chosen from the menu bar or the Dock menu.
///
/// The raw values are the `DesktopCommand` names in
/// `lib/services/desktop_menu_service.dart`.
enum DesktopCommand: String {
  case playPause
  case next
  case previous
  case toggleFavorite
  case search
  case settings
  case nowPlaying
  case back
  case forward
  case volumeUp
  case volumeDown
  case toggleMute
}

/// What the Flutter shell last reported as playing.
struct DesktopPlaybackState {
  /// False until a station is picked, when the playback items have nothing
  /// to act on.
  var hasStation = false
  var playing = false
  var isFavorite = false
  /// Whether the volume is at 0, for the mute item to turn it back on.
  var muted = false
  /// The stations last listened to, newest first, the playing one left
  /// out, for the Dock menu's "Ascultate recent".
  var recent: [RecentStation] = []
}

/// A station the Dock menu offers to play again.
struct RecentStation {
  let slug: String
  let title: String
}

/// Carries menu choices to the Flutter shell and playback state back.
///
/// Speaks `com.radiocrestin.desktop_menu`: a menu choice goes to Dart as
/// `command` with a `DesktopCommand` name, and Dart reports what is playing
/// with `state` ({hasStation, playing, isFavorite, muted, recent}). The menus read
/// [state] when AppKit validates them, so their titles follow playback.
/// Dart asks with `show` for the window, closed or minimized, to come
/// back, as when a link opens a station, says `ready` once its first frame
/// is on screen, by when the window's title bar is laid out, and `dragArea`
/// whether the pointer is on an empty part of the top bar. Dart asks with
/// `titleBar` where the window buttons sit over the top bar, and is told
/// again with `titleBar` as they hide and come back with full screen.
final class DesktopMenuChannel {
  static let shared = DesktopMenuChannel()

  private static let channelName = "com.radiocrestin.desktop_menu"

  private var channel: FlutterMethodChannel?

  /// The last state Dart reported.
  private(set) var state = DesktopPlaybackState()

  /// Brings the main window back; set by the app delegate, which keeps it.
  var showWindow: (() -> Void)?

  /// Called once Flutter's first frame is on screen; set by the window.
  var onFirstFrame: (() -> Void)?

  /// Called with whether the pointer rests on an empty part of the top
  /// bar, where a press moves the window; set by the window.
  var onDragAreaChange: ((Bool) -> Void)?

  /// Where the window buttons sit over the top bar, as `{leading,
  /// height}`; set by the window.
  var titleBar: (() -> [String: Double])?

  private init() {}

  /// Opens the channel on the main Flutter engine. The shared instance
  /// keeps it for the life of the app.
  func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      DesktopMenuChannel.shared.handle(call, result: result)
    }
    self.channel = channel
  }

  /// Hands [command] to the Flutter shell.
  func send(_ command: DesktopCommand) {
    channel?.invokeMethod("command", arguments: command.rawValue)
  }

  /// Tells the Flutter shell where the window buttons now sit.
  func sendTitleBar(_ geometry: [String: Double]) {
    channel?.invokeMethod("titleBar", arguments: geometry)
  }

  /// Asks the Flutter shell to play the station with [slug].
  func playStation(slug: String) {
    channel?.invokeMethod("playStation", arguments: slug)
  }

  private func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "state":
      updateState(call.arguments, result: result)
    case "show":
      showWindow?()
      result(nil)
    case "ready":
      onFirstFrame?()
      result(nil)
    case "dragArea":
      onDragAreaChange?(call.arguments as? Bool ?? false)
      result(nil)
    case "titleBar":
      result(titleBar?() ?? [:])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func updateState(
    _ arguments: Any?,
    result: @escaping FlutterResult
  ) {
    guard let arguments = arguments as? [String: Any] else {
      result(
        FlutterError(
          code: "bad_args",
          message: "state takes {hasStation, playing, isFavorite}",
          details: nil
        )
      )
      return
    }
    let recent = (arguments["recent"] as? [[String: Any]] ?? []).compactMap {
      entry -> RecentStation? in
      guard let slug = entry["slug"] as? String,
        let title = entry["title"] as? String
      else { return nil }
      return RecentStation(slug: slug, title: title)
    }
    state = DesktopPlaybackState(
      hasStation: arguments["hasStation"] as? Bool ?? false,
      playing: arguments["playing"] as? Bool ?? false,
      isFavorite: arguments["isFavorite"] as? Bool ?? false,
      muted: arguments["muted"] as? Bool ?? false,
      recent: recent
    )
    result(nil)
  }
}
