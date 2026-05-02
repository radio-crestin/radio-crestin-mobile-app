import SwiftUI

@main
struct RadioCrestinTVApp: App {
    init() {
        // Bootstrap analytics + crash capture before any view code runs
        // so a hard failure during state setup still gets reported.
        Analytics.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
