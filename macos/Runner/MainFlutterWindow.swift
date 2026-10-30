import Cocoa
import FlutterMacOS

/// The app's only window, hosting the Flutter desktop shell.
///
/// It is dark, and the shell's top bar runs under its transparent title
/// bar, beside the close, minimize and zoom buttons, which sit centered on
/// the bar; it keeps its size and position across launches. Closing it only
/// hides it: the radio keeps playing and the Dock icon brings it back.
/// Until Flutter's first frame, a moment after launch, it shows the
/// shell's dark background, never a white or flashing window.
class MainFlutterWindow: NSWindow {
  /// `TvColors.background` in `lib/tv/tv_theme.dart` (#0A0A0A).
  private static let shellBackground = NSColor(
    srgbRed: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)

  /// The smallest area the desktop layouts are built for.
  private static let minimumContentSize = NSSize(width: 760, height: 560)

  /// The window at first launch: five columns of cards and the player bar,
  /// without taking the whole screen. Later launches restore the last one.
  private static let defaultContentSize = NSSize(width: 1100, height: 780)

  private static let frameAutosaveName = "RadioCrestinMainWindow"

  /// Whether the pointer rests on an empty part of the Flutter top bar,
  /// where a press moves the window, as Dart last said.
  private var isOverDragArea = false

  /// Called with true when a Flutter text field starts being edited and
  /// with false when it stops.
  ///
  /// Flutter's text input plugin is an `NSTextView` that is the first
  /// responder exactly while a text field is shown.
  var onTextEditingChange: ((Bool) -> Void)?

  private var isEditingText = false

  /// A press on an empty part of the top bar moves the window, and a
  /// double-click there does what a title bar's does. Flutter can't move
  /// the window, and needs the press itself to start the move.
  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown, isOverDragArea,
      !isOnWindowButton(event.locationInWindow)
    {
      if event.clickCount == 2 {
        performTitleBarDoubleClick()
      } else {
        performDrag(with: event)
      }
      return
    }
    super.sendEvent(event)
  }

  /// Whether [point] is on the close, minimize or zoom button.
  private func isOnWindowButton(_ point: NSPoint) -> Bool {
    let kinds: [NSWindow.ButtonType] = [
      .closeButton, .miniaturizeButton, .zoomButton,
    ]
    return kinds.contains { kind in
      guard let button = standardWindowButton(kind) else { return false }
      return button.convert(button.bounds, to: nil).contains(point)
    }
  }

  /// What the system's "double-click a window's title bar" setting says:
  /// zoom (the default), minimize, or nothing.
  private func performTitleBarDoubleClick() {
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize":
      performMiniaturize(nil)
    case "None":
      break
    default:
      performZoom(nil)
    }
  }

  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    let accepted = super.makeFirstResponder(responder)
    let editing = firstResponder is NSTextView
    if editing != isEditingText {
      isEditingText = editing
      onTextEditingChange?(editing)
    }
    return accepted
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Painted until Flutter's first frame, so the window never flashes white.
    flutterViewController.backgroundColor = Self.shellBackground
    contentViewController = flutterViewController

    configureChrome()
    configureFrame()
    DesktopMenuChannel.shared.onFirstFrame = { [weak self] in
      // The title bar is laid out by now.
      self?.leaveTitleBarDoubleClickToShell()
    }
    DesktopMenuChannel.shared.onDragAreaChange = { [weak self] over in
      self?.isOverDragArea = over
    }
    DesktopMenuChannel.shared.titleBar = { [weak self] in
      self?.titleBarGeometry() ?? [:]
    }
    followFullScreen()
    leaveTitleBarDoubleClickToShell()

    RegisterGeneratedPlugins(registry: flutterViewController)
    DesktopMenuChannel.shared.attach(
      to: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  private func configureChrome() {
    // Mission Control and the Dock still name the window; the shell shows
    // the brand in its own top bar, so the title bar stays empty.
    title = "Radio Crestin"
    titleVisibility = .hidden
    // The shell's top bar runs under the transparent title bar, beside the
    // window buttons, rather than below an empty strip. Clicks there still
    // reach Flutter: only the buttons themselves take them.
    styleMask.insert(.fullSizeContentView)
    titlebarAppearsTransparent = true
    titlebarSeparatorStyle = .none
    // An empty unified toolbar makes the title bar as tall as the top bar:
    // macOS then centers the buttons on it, and keeps them there as the
    // window is resized or leaves full screen.
    let toolbar = NSToolbar(identifier: "RadioCrestinTitleBar")
    toolbar.allowsUserCustomization = false
    self.toolbar = toolbar
    toolbarStyle = .unified
    appearance = NSAppearance(named: .darkAqua)
    backgroundColor = Self.shellBackground

    isReleasedWhenClosed = false
    // The Window menu has its own "Radio Crestin" item, which also works
    // once the window is closed.
    isExcludedFromWindowsMenu = true
    styleMask.insert(.resizable)
    collectionBehavior.insert(.fullScreenPrimary)
  }

  /// Where the window buttons sit, for the top bar to make room for them
  /// and center itself on them: where they end from the window's start
  /// (`leading`) and the bar height that centers them (`height`); 0 for
  /// both while they are hidden, in full screen.
  private func titleBarGeometry(fullScreen: Bool? = nil) -> [String: Double] {
    let hidden = ["leading": 0.0, "height": 0.0]
    guard !(fullScreen ?? styleMask.contains(.fullScreen)),
      let zoom = standardWindowButton(.zoomButton), !zoom.isHidden
    else { return hidden }
    let button = zoom.convert(zoom.bounds, to: nil)
    let centerFromTop = frame.height - button.midY
    return ["leading": Double(button.maxX), "height": Double(2 * centerFromTop)]
  }

  /// Leaves double-clicks in the title bar to the shell.
  ///
  /// The shell's top bar runs under the title bar, where macOS's own
  /// double-click recognizer sees every click, the bar's buttons' too: two
  /// quick clicks on search or Settings zoomed the window. The bar's empty
  /// parts still zoom it, as a title bar does (see `sendEvent`).
  ///
  /// The recognizer is found by its action, which only recent macOS has;
  /// earlier versions handle the double-click in the title bar's own view,
  /// which the shell's clicks never reach.
  private func leaveTitleBarDoubleClickToShell() {
    let action = NSSelectorFromString("_handleTitledFrameDoubleClickGesture:")
    for recognizer in contentView?.superview?.gestureRecognizers ?? []
    where recognizer.action == action {
      recognizer.isEnabled = false
    }
  }

  /// Tells the shell when the buttons go, as full screen starts, and when
  /// they are back, once it ended.
  private func followFullScreen() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: NSWindow.willEnterFullScreenNotification, object: self,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      DesktopMenuChannel.shared.sendTitleBar(
        self.titleBarGeometry(fullScreen: true))
    }
    center.addObserver(
      forName: NSWindow.didExitFullScreenNotification, object: self,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      DesktopMenuChannel.shared.sendTitleBar(
        self.titleBarGeometry(fullScreen: false))
      // Its title bar back, in case macOS set it up anew.
      self.leaveTitleBarDoubleClickToShell()
    }
  }

  /// Restores the last frame, or centers a default one on first launch.
  private func configureFrame() {
    contentMinSize = Self.minimumContentSize
    if !setFrameUsingName(Self.frameAutosaveName) {
      setFrame(Self.defaultFrame(on: screen ?? NSScreen.main), display: false)
    }
    growToMinimumSize()
    setFrameAutosaveName(Self.frameAutosaveName)
  }

  /// A saved frame can predate the minimum size; grow it, keeping its
  /// top-left corner in place.
  private func growToMinimumSize() {
    let content = contentRect(forFrameRect: frame)
    let minimum = Self.minimumContentSize
    guard content.width < minimum.width || content.height < minimum.height
    else { return }

    let grownContent = NSRect(
      x: content.minX,
      y: content.minY,
      width: max(content.width, minimum.width),
      height: max(content.height, minimum.height))
    var grown = frameRect(forContentRect: grownContent)
    grown.origin.y = frame.maxY - grown.height
    setFrame(grown, display: false)
  }

  /// [defaultContentSize] centered on [screen], smaller on small screens
  /// but never below the minimum size.
  private static func defaultFrame(on screen: NSScreen?) -> NSRect {
    let visible = screen?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let width = max(
      minimumContentSize.width,
      min(defaultContentSize.width, visible.width * 0.8))
    let height = max(
      minimumContentSize.height,
      min(defaultContentSize.height, visible.height * 0.8))
    return NSRect(
      x: (visible.midX - width / 2).rounded(),
      y: (visible.midY - height / 2).rounded(),
      width: width,
      height: height)
  }
}
