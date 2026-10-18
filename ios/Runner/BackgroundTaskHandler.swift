import Flutter
import UIKit

/// Holds iOS background time for Dart: `beginBackgroundTask`, which keeps
/// the app running a while (about 30 s, as iOS decides) after it would
/// otherwise be suspended in the background.
///
/// One task at a time: `begin` replaces the last one, `end` ends it, and
/// so does iOS once the time runs out, when the app is suspended as usual.
class BackgroundTaskHandler {
    private var task: UIBackgroundTaskIdentifier = .invalid

    static func register(with messenger: FlutterBinaryMessenger) {
        let handler = BackgroundTaskHandler()
        FlutterMethodChannel(
            name: "com.radiocrestin.background_task",
            binaryMessenger: messenger
        ).setMethodCallHandler { call, result in
            switch call.method {
            case "begin":
                result(handler.begin())
            case "end":
                handler.end()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Whether iOS granted the time.
    private func begin() -> Bool {
        end()
        task = UIApplication.shared.beginBackgroundTask(
            withName: "PausedStream"
        ) { [weak self] in
            self?.end()
        }
        return task != .invalid
    }

    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
