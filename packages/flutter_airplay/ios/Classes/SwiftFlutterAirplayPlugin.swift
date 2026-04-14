import Flutter
import UIKit

public class SwiftFlutterAirplayPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        registrar.register(
            RoutePickerViewFactory(messenger: registrar.messenger()),
            withId: "airplay_route_picker_view",
            gestureRecognizersBlockingPolicy: FlutterPlatformViewGestureRecognizersBlockingPolicy(rawValue: 0))
    }
}
