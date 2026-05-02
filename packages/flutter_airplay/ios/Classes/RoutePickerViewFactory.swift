import Foundation
import Flutter

class RoutePickerViewFactory: NSObject, FlutterPlatformViewFactory {
    let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger & NSObjectProtocol) {
        self.messenger = messenger
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        let arguments = args as? Dictionary<String, Any> ?? [:]
        return FlutterRoutePickerView(messenger: messenger, viewId: viewId, arguments: arguments)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}
