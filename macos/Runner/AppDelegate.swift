import Cocoa
import FlutterMacOS
import FirebaseCore

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    FirebaseApp.configure()
    return true
  }
}
