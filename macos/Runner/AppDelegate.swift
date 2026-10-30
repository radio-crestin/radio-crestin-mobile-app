import Cocoa
import FirebaseCore
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private static let websiteURL = URL(string: "https://www.radiocrestin.ro")!
  private static let nextStationKey = String(
    Character(UnicodeScalar(NSRightArrowFunctionKey)!))
  private static let previousStationKey = String(
    Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
  private static let volumeUpKey = String(
    Character(UnicodeScalar(NSUpArrowFunctionKey)!))
  private static let volumeDownKey = String(
    Character(UnicodeScalar(NSDownArrowFunctionKey)!))

  /// Kept so the window outlives being closed and the Dock icon, the
  /// Window menu or a menu command can show it again.
  private var mainWindow: NSWindow?

  private var menuChannel: DesktopMenuChannel { .shared }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    // A single window: no tab bar items in the View and Window menus.
    NSWindow.allowsAutomaticWindowTabbing = false
    super.applicationWillFinishLaunching(notification)
  }

  /// Doesn't call super: FlutterAppDelegate doesn't implement this method,
  /// and calling it raised an unrecognized-selector exception at launch.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // The Flutter engine starts with the window, before this runs, and its
    // `Firebase.initializeApp` usually configures Firebase first. Configuring
    // it twice raises an exception that AppKit swallows, skipping the rest of
    // this method.
    if FirebaseApp.app() == nil {
      FirebaseApp.configure()
    }
    mainWindow = mainFlutterWindow
    (mainWindow as? MainFlutterWindow)?.onTextEditingChange = {
      [weak self] editing in
      self?.setStationArrowShortcuts(enabled: !editing)
    }
    // A link opening a station activates the app, which doesn't bring a
    // closed window back by itself.
    menuChannel.showWindow = { [weak self] in self?.revealMainWindow() }
  }

  /// Quits at once when the Mac logs out, restarts or shuts down.
  ///
  /// Otherwise Flutter first cancels the quit and asks the shell, which
  /// stops playback before agreeing (`didRequestAppExit`); a cancelled quit
  /// would cancel the logout ("Radio Crestin canceled log out").
  override func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    if Self.isSessionEnding { return .terminateNow }
    return super.applicationShouldTerminate(sender)
  }

  /// Whether the quit being handled comes from a logout, restart or
  /// shutdown.
  private static var isSessionEnding: Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventClass == AEEventClass(kCoreEventClass),
      event.eventID == AEEventID(kAEQuitApplication)
    else { return false }
    let keyword = AEKeyword(kAEQuitReason)
    let reason = event.attributeDescriptor(forKeyword: keyword)
      ?? event.paramDescriptor(forKeyword: keyword)
    guard let code = reason?.enumCodeValue else { return false }
    let sessionEndings = [
      kAEQuitAll, kAELogOut, kAEReallyLogOut, kAEShowRestartDialog,
      kAEShowShutdownDialog, kAERestart, kAEShutDown,
    ].map { OSType($0) }
    return sessionEndings.contains(code)
  }

  /// Closing the window leaves the radio playing, as in Apple Music: the
  /// app quits only with ⌘Q or from the Dock.
  override func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(
    _ app: NSApplication
  ) -> Bool {
    return true
  }

  /// A click on the Dock icon brings back a closed or minimized window.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if flag { return true }
    revealMainWindow()
    return false
  }

  /// The playback controls, once a station was picked.
  override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let state = menuChannel.state
    guard state.hasStation else { return nil }

    // Grouped as music apps' Dock menus are: play, then the skips, then
    // the favorite, then what was listened to lately.
    let menu = NSMenu()
    addDockItem(
      PlaybackMenuTitles.playPause(state), #selector(togglePlayback(_:)),
      to: menu)
    menu.addItem(.separator())
    addDockItem(
      PlaybackMenuTitles.next, #selector(playNextStation(_:)), to: menu)
    addDockItem(
      PlaybackMenuTitles.previous, #selector(playPreviousStation(_:)),
      to: menu)
    menu.addItem(.separator())
    addDockItem(
      PlaybackMenuTitles.favorite(state), #selector(toggleFavorite(_:)),
      to: menu)
    addRecentStations(state.recent, to: menu)
    return menu
  }

  /// "Ascultate recent": a title, then the stations under it, each playing
  /// its station.
  private func addRecentStations(
    _ stations: [RecentStation], to menu: NSMenu
  ) {
    guard !stations.isEmpty else { return }
    menu.addItem(.separator())
    let title = NSMenuItem(
      title: PlaybackMenuTitles.recent, action: nil, keyEquivalent: "")
    title.isEnabled = false
    menu.addItem(title)
    for station in stations {
      let item = NSMenuItem(
        title: station.title, action: #selector(playRecentStation(_:)),
        keyEquivalent: "")
      item.target = self
      item.indentationLevel = 1
      item.representedObject = station.slug
      menu.addItem(item)
    }
  }

  @objc private func playRecentStation(_ sender: NSMenuItem) {
    guard let slug = sender.representedObject as? String else { return }
    menuChannel.playStation(slug: slug)
  }

  /// Gives ⌘→, ⌘←, ⌘↑ and ⌘↓ to a text field while one is edited, where
  /// they move the caret.
  ///
  /// Flutter hands the keys a text field passes on to the menu bar, which
  /// would then skip the station; the items still work with the mouse.
  private func setStationArrowShortcuts(enabled: Bool) {
    let shortcuts: [Selector: String] = [
      #selector(playNextStation(_:)): Self.nextStationKey,
      #selector(playPreviousStation(_:)): Self.previousStationKey,
      #selector(volumeUp(_:)): Self.volumeUpKey,
      #selector(volumeDown(_:)): Self.volumeDownKey,
    ]
    for item in Self.items(in: NSApp.mainMenu) {
      guard let action = item.action, let key = shortcuts[action] else {
        continue
      }
      item.keyEquivalent = enabled ? key : ""
    }
  }

  /// Every item of [menu] and of its submenus.
  private static func items(in menu: NSMenu?) -> [NSMenuItem] {
    (menu?.items ?? []).flatMap { [$0] + items(in: $0.submenu) }
  }

  private func addDockItem(
    _ title: String, _ action: Selector, to menu: NSMenu
  ) {
    let item = menu.addItem(
      withTitle: title, action: action, keyEquivalent: "")
    item.target = self
  }

  // MARK: - Menu actions

  @IBAction func togglePlayback(_ sender: Any?) {
    menuChannel.send(.playPause)
  }

  @IBAction func playNextStation(_ sender: Any?) {
    menuChannel.send(.next)
  }

  @IBAction func playPreviousStation(_ sender: Any?) {
    menuChannel.send(.previous)
  }

  @IBAction func toggleFavorite(_ sender: Any?) {
    menuChannel.send(.toggleFavorite)
  }

  @IBAction func showSearch(_ sender: Any?) {
    revealMainWindow()
    menuChannel.send(.search)
  }

  @IBAction func showSettings(_ sender: Any?) {
    revealMainWindow()
    menuChannel.send(.settings)
  }

  @IBAction func showNowPlaying(_ sender: Any?) {
    revealMainWindow()
    menuChannel.send(.nowPlaying)
  }

  @IBAction func showMainWindow(_ sender: Any?) {
    revealMainWindow()
  }

  /// Back and forward, as in a browser: ⌘[ and ⌘], which some mouse
  /// drivers send for their side buttons. The shell decides what they do.
  @IBAction func goBack(_ sender: Any?) {
    menuChannel.send(.back)
  }

  @IBAction func goForward(_ sender: Any?) {
    menuChannel.send(.forward)
  }

  @IBAction func volumeUp(_ sender: Any?) {
    menuChannel.send(.volumeUp)
  }

  @IBAction func volumeDown(_ sender: Any?) {
    menuChannel.send(.volumeDown)
  }

  /// Mutes or unmutes; M does the same in the window.
  @IBAction func toggleMute(_ sender: Any?) {
    menuChannel.send(.toggleMute)
  }

  @IBAction func openWebsite(_ sender: Any?) {
    NSWorkspace.shared.open(Self.websiteURL)
  }

  private func revealMainWindow() {
    guard let window = mainWindow ?? mainFlutterWindow else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }
}

extension AppDelegate: NSMenuItemValidation {
  /// Titles the playback items after what is playing and disables them
  /// until a station is picked.
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    let state = menuChannel.state
    switch menuItem.action {
    case #selector(togglePlayback(_:)):
      menuItem.title = PlaybackMenuTitles.playPause(state)
      return state.hasStation
    case #selector(toggleFavorite(_:)):
      menuItem.title = PlaybackMenuTitles.favorite(state)
      return state.hasStation
    case #selector(toggleMute(_:)):
      menuItem.title = PlaybackMenuTitles.mute(state)
      return true
    case #selector(playNextStation(_:)),
      #selector(playPreviousStation(_:)),
      #selector(showNowPlaying(_:)):
      return state.hasStation
    case #selector(showMainWindow(_:)):
      let isFront = mainWindow?.isVisible == true
        && mainWindow?.isMainWindow == true
      menuItem.state = isFront ? .on : .off
      return true
    default:
      return true
    }
  }
}

/// The titles of the items that follow playback, shared by the menu bar
/// and the Dock menu.
private enum PlaybackMenuTitles {
  static let next = "Stația următoare"
  static let previous = "Stația anterioară"
  static let recent = "Ascultate recent"

  static func playPause(_ state: DesktopPlaybackState) -> String {
    state.playing ? "Pauză" : "Redă"
  }

  static func favorite(_ state: DesktopPlaybackState) -> String {
    state.isFavorite ? "Elimină din favorite" : "Adaugă la favorite"
  }

  static func mute(_ state: DesktopPlaybackState) -> String {
    state.muted ? "Pornește sunetul" : "Fără sunet"
  }
}
