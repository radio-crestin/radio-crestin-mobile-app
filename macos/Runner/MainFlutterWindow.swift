import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Set a good default size for a desktop radio app (16:10 aspect ratio)
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let windowWidth: CGFloat = min(1280, screenFrame.width * 0.8)
    let windowHeight: CGFloat = min(800, screenFrame.height * 0.8)
    let originX = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
    let originY = screenFrame.origin.y + (screenFrame.height - windowHeight) / 2
    self.setFrame(NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight), display: true)

    // Allow resizing with a reasonable minimum
    self.minSize = NSSize(width: 800, height: 500)
    self.styleMask.insert(.resizable)
    self.title = "Radio Crestin"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
