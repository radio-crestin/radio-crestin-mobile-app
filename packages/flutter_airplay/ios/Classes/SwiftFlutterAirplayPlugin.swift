import Flutter
import UIKit
import AVFoundation
import AVKit
import MediaPlayer

public class SwiftFlutterAirplayPlugin: NSObject, FlutterPlugin {
    private static var methodChannel: FlutterMethodChannel?
    private static var routeDetector: AVRouteDetector?

    public static func register(with registrar: FlutterPluginRegistrar) {
        // Platform view for route picker button
        registrar.register(
            RoutePickerViewFactory(messenger: registrar.messenger()),
            withId: "airplay_route_picker_view",
            gestureRecognizersBlockingPolicy: FlutterPlatformViewGestureRecognizersBlockingPolicy(rawValue: 0))

        // Method channel for route state monitoring
        let channel = FlutterMethodChannel(name: "flutter_airplay/route_state", binaryMessenger: registrar.messenger())
        let instance = SwiftFlutterAirplayPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        methodChannel = channel

        // Start monitoring audio routes
        instance.startRouteMonitoring()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAirPlayActive":
            result(SwiftFlutterAirplayPlugin.isAirPlayActive())
        case "isAirPlayAvailable":
            result(SwiftFlutterAirplayPlugin.routeDetector?.multipleRoutesDetected ?? false)
        case "getCurrentRouteName":
            result(SwiftFlutterAirplayPlugin.getCurrentRouteName())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startRouteMonitoring() {
        // Route detector — monitors if AirPlay routes are available on the network
        let detector = AVRouteDetector()
        detector.isRouteDetectionEnabled = true
        SwiftFlutterAirplayPlugin.routeDetector = detector

        // Observe multipleRoutesDetected changes
        detector.addObserver(self, forKeyPath: "multipleRoutesDetected", options: [.new], context: nil)

        // Listen for audio route changes (AirPlay connect/disconnect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        // Send initial state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            SwiftFlutterAirplayPlugin.sendRouteState()
        }
    }

    @objc private func audioRouteChanged(_ notification: Notification) {
        SwiftFlutterAirplayPlugin.sendRouteState()
    }

    public override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey : Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "multipleRoutesDetected" {
            SwiftFlutterAirplayPlugin.sendRouteState()
        }
    }

    private static func sendRouteState() {
        DispatchQueue.main.async {
            methodChannel?.invokeMethod("onRouteStateChanged", arguments: [
                "isAirPlayActive": isAirPlayActive(),
                "isAirPlayAvailable": routeDetector?.multipleRoutesDetected ?? false,
                "routeName": getCurrentRouteName() ?? "",
            ])
        }
    }

    private static func isAirPlayActive() -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        for output in route.outputs {
            if output.portType == .airPlay {
                return true
            }
        }
        return false
    }

    private static func getCurrentRouteName() -> String? {
        let route = AVAudioSession.sharedInstance().currentRoute
        for output in route.outputs {
            if output.portType == .airPlay {
                return output.portName
            }
        }
        return nil
    }
}
