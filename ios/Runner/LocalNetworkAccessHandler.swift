import Flutter
import Network
import UIKit

/// Tells Flutter whether iOS lets the app reach the local network.
///
/// iOS has no API to read the Local Network permission, and without it the
/// Cast SDK just finds no devices, which looks the same as a home with no
/// Chromecast. A Bonjour browse for Cast devices tells the two apart: while
/// access is blocked, the browser waits with `kDNSServiceErr_PolicyDenied`.
///
/// The browse runs only while Dart listens. It restarts each time the app
/// becomes active, so an answer to the permission prompt or a change made
/// in Settings is reported on return.
class LocalNetworkAccessHandler: NSObject, FlutterStreamHandler {
    private var browser: NWBrowser?
    private var events: FlutterEventSink?
    private var activeObserver: NSObjectProtocol?

    static func register(with messenger: FlutterBinaryMessenger) {
        FlutterEventChannel(
            name: "com.radiocrestin.local_network",
            binaryMessenger: messenger
        ).setStreamHandler(LocalNetworkAccessHandler())
    }

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        self.events = events
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startBrowsing()
        }
        startBrowsing()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        activeObserver = nil
        browser?.cancel()
        browser = nil
        events = nil
        return nil
    }

    private func startBrowsing() {
        browser?.cancel()
        let browser = NWBrowser(
            for: .bonjour(type: "_googlecast._tcp", domain: nil),
            using: NWParameters()
        )
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            // A replaced browser can still report while it shuts down.
            guard let self, let browser, self.browser === browser else {
                return
            }
            switch state {
            case .ready:
                self.events?("granted")
            case .waiting(.dns(let code))
                where code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied):
                self.events?("denied")
            default:
                break
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }
}
