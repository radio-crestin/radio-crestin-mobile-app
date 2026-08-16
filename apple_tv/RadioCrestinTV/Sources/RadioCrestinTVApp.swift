import SwiftUI

@main
struct RadioCrestinTVApp: App {
    init() {
        // Bootstrap analytics + crash capture before any view code runs
        // so a hard failure during state setup still gets reported.
        Analytics.bootstrap()
        #if DEBUG
        // The private-stations allowlist is keyed on this value; printing
        // it on every debug launch saves digging through the simulator's
        // preferences plist when a device needs allowlisting server-side.
        print("RadioCrestinTV: device_id = \(DeviceIdentity.deviceId)")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
