import Foundation
import AVKit
import MediaPlayer
import Flutter

class FlutterRoutePickerView: NSObject, FlutterPlatformView {
    private var pickerView: UIView
    private var delegate: AVRoutePickerViewDelegate?

    init(messenger: FlutterBinaryMessenger, viewId: Int64, arguments: Dictionary<String, Any>) {
        if #available(iOS 11.0, *) {
            let routePickerView = AVRoutePickerView(frame: .init(x: 0, y: 0, width: 44, height: 44))

            if let tintColor = arguments["tintColor"] as? Dictionary<String, Any> {
                routePickerView.tintColor = FlutterRoutePickerView.mapToColor(tintColor)
            }
            if let activeTintColor = arguments["activeTintColor"] as? Dictionary<String, Any> {
                routePickerView.activeTintColor = FlutterRoutePickerView.mapToColor(activeTintColor)
            }
            if let backgroundColor = arguments["backgroundColor"] as? Dictionary<String, Any> {
                routePickerView.backgroundColor = FlutterRoutePickerView.mapToColor(backgroundColor)
            }

            // Audio-focused: don't prioritize video devices
            if #available(iOS 13.0, *) {
                routePickerView.prioritizesVideoDevices = arguments["prioritizesVideoDevices"] as? Bool ?? false
            }

            delegate = RoutePickerDelegate(viewId: viewId, messenger: messenger)
            routePickerView.delegate = delegate

            pickerView = routePickerView
        } else {
            // Fallback for iOS < 11: MPVolumeView with AirPlay button
            let volumeView = MPVolumeView(frame: .init(x: 0, y: 0, width: 44, height: 44))
            volumeView.showsVolumeSlider = false
            pickerView = volumeView
        }
    }

    func view() -> UIView {
        return pickerView
    }

    static func mapToColor(_ map: Dictionary<String, Any>) -> UIColor {
        return UIColor(
            red: CGFloat(truncating: map["red"] as! NSNumber),
            green: CGFloat(truncating: map["green"] as! NSNumber),
            blue: CGFloat(truncating: map["blue"] as! NSNumber),
            alpha: CGFloat(truncating: map["alpha"] as! NSNumber)
        )
    }
}

class RoutePickerDelegate: NSObject, AVRoutePickerViewDelegate {
    let methodChannel: FlutterMethodChannel

    init(viewId: Int64, messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(name: "flutter_airplay#\(viewId)", binaryMessenger: messenger)
    }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        methodChannel.invokeMethod("onShowPickerView", arguments: nil)
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        methodChannel.invokeMethod("onClosePickerView", arguments: nil)
    }
}
