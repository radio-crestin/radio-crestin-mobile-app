import CryptoKit
import Flutter
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

/// Connects the Home Screen widgets with the Flutter side of the app.
///
/// Flutter sends what the widgets show (`save`); it is saved in the App
/// Group container with the images it names, and the widgets reload. The
/// widgets' buttons come back through `WidgetCommandCenter` and go to
/// Flutter as `command` once Flutter is `ready`: a button can launch the
/// app in the background, before Flutter runs.
@MainActor
final class HomeWidgetBridge {
    static let shared = HomeWidgetBridge()

    private static let channelName = "com.radiocrestin.home_widgets"
    /// How long a button waits for Flutter to start after a launch.
    private static let readyTimeout: UInt64 = 20
    /// How long a button waits for Flutter to carry it out.
    private static let commandTimeout: UInt64 = 10

    private var channel: FlutterMethodChannel?
    private var flutterReady = false
    private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private let store = WidgetSnapshotStore()

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: Self.channelName,
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            Task { @MainActor in
                HomeWidgetBridge.shared.handle(call, result: result)
            }
        }
        self.channel = channel
        WidgetCommandCenter.handler = { command in
            await HomeWidgetBridge.shared.send(command)
        }
    }

    /// The app is quitting: its audio stops, so the widgets stop showing
    /// it playing.
    func appWillTerminate() {
        WidgetSnapshotStore.markStopped()
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "save":
            guard let json = (call.arguments as? String)?.data(using: .utf8) else {
                result(FlutterError(code: "bad_args", message: "save takes JSON", details: nil))
                return
            }
            Task {
                await store.save(json)
                result(nil)
            }
        case "heartbeat":
            Task {
                await store.confirmPlaying()
                result(nil)
            }
        case "ready":
            flutterReady = true
            let waiters = readyWaiters.values
            readyWaiters.removeAll()
            waiters.forEach { $0.resume(returning: true) }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Carries out a widget button in Flutter; returns once Flutter has,
    /// so the widget redraws with its outcome.
    private func send(_ command: WidgetCommand) async {
        NSLog("HomeWidgetBridge: \(command.arguments)")
        guard await waitForFlutter() else {
            NSLog("HomeWidgetBridge: Flutter didn't start, dropped the button")
            return
        }
        guard let channel else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once { continuation.resume() }
            channel.invokeMethod("command", arguments: command.arguments) { _ in
                once.run()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.commandTimeout * NSEC_PER_SEC)
                once.run()
            }
        }
    }

    private func waitForFlutter() async -> Bool {
        if flutterReady { return true }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            readyWaiters[id] = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.readyTimeout * NSEC_PER_SEC)
                readyWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }
}

/// Runs its action the first time only: a reply and its timeout race.
@MainActor
private final class Once {
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func run() {
        action?()
        action = nil
    }
}

private extension WidgetCommand {
    var arguments: [String: Any] {
        switch self {
        case let .play(slug, fromFavorites):
            return ["action": "play", "slug": slug, "fromFavorites": fromFavorites]
        case .pause:
            return ["action": "pause"]
        case let .skip(forward):
            return ["action": forward ? "next" : "previous"]
        }
    }
}

/// What Flutter sends for the widgets: `WidgetSnapshot` with image URLs,
/// and the file the app already cached for each, when it has.
private struct WidgetPayload: Decodable {
    struct Image: Decodable {
        let url: String
        let path: String?
    }

    struct Station: Decodable {
        let slug: String
        let title: String
        let logo: Image?
    }

    let isPlaying: Bool
    let station: Station?
    let song: WidgetSnapshot.Song?
    let cover: Image?
    let listeners: Int?
    let previousSlug: String?
    let nextSlug: String?
    let favorites: [Station]
    let favoriteCount: Int
}

/// Saves what the widgets show, with its images, and reloads the widgets
/// whose content changed.
actor WidgetSnapshotStore {
    /// Counts the saves begun: one that a newer save overtook while it
    /// fetched images gives way to it.
    private var generation = 0

    /// Whether this launch reloaded every widget yet. An app update brings
    /// new widget code, which draws nothing until its widget reloads, and
    /// a widget whose content didn't change wouldn't.
    private var reloadedAll = false

    func save(_ json: Data) async {
        generation += 1
        let mine = generation
        let payload: WidgetPayload
        do {
            payload = try JSONDecoder().decode(WidgetPayload.self, from: json)
        } catch {
            NSLog("WidgetSnapshotStore: unreadable payload: \(error)")
            return
        }
        let snapshot = await snapshot(of: payload)
        guard mine == generation else { return }

        let previous = WidgetStorage.loadSnapshot()
        if let previous, previous.showsSame(as: snapshot), reloadedAll { return }
        guard WidgetStorage.save(snapshot) else { return }
        WidgetImages.prune(keeping: snapshot)
        let kinds = reloadedAll
            ? Self.kindsToReload(from: previous, to: snapshot)
            : [WidgetKind.nowPlaying, WidgetKind.favorites]
        reloadedAll = true
        await MainActor.run {
            kinds.forEach { WidgetCenter.shared.reloadTimelines(ofKind: $0) }
        }
    }

    private func snapshot(of payload: WidgetPayload) async -> WidgetSnapshot {
        var favorites: [WidgetSnapshot.Station] = []
        for station in payload.favorites {
            favorites.append(await Self.station(station))
        }
        var station: WidgetSnapshot.Station?
        if let current = payload.station {
            station = await Self.station(current)
        }
        let now = Date()
        return WidgetSnapshot(
            isPlaying: payload.isPlaying,
            station: station,
            song: payload.song,
            cover: await WidgetImages.file(for: payload.cover, kind: .cover),
            listeners: payload.listeners,
            listenersAt: payload.listeners == nil ? nil : now,
            previousSlug: payload.previousSlug,
            nextSlug: payload.nextSlug,
            favorites: favorites,
            favoriteCount: payload.favoriteCount,
            savedAt: now
        )
    }

    private static func station(
        _ station: WidgetPayload.Station
    ) async -> WidgetSnapshot.Station {
        WidgetSnapshot.Station(
            slug: station.slug,
            title: station.title,
            logo: await WidgetImages.file(for: station.logo, kind: .logo)
        )
    }

    /// The widgets that show something of what changed.
    private static func kindsToReload(
        from previous: WidgetSnapshot?,
        to snapshot: WidgetSnapshot
    ) -> [String] {
        guard let previous else {
            return [WidgetKind.nowPlaying, WidgetKind.favorites]
        }
        var kinds: [String] = []
        let nowPlayingChanged = previous.isPlaying != snapshot.isPlaying
            || previous.station != snapshot.station
            || previous.song != snapshot.song
            || previous.cover != snapshot.cover
            || previous.listeners != snapshot.listeners
            || previous.previousSlug != snapshot.previousSlug
            || previous.nextSlug != snapshot.nextSlug
        if nowPlayingChanged { kinds.append(WidgetKind.nowPlaying) }
        let favoritesChanged = previous.isPlaying != snapshot.isPlaying
            || previous.station?.slug != snapshot.station?.slug
            || previous.song?.title != snapshot.song?.title
            || previous.favorites != snapshot.favorites
            || previous.favoriteCount != snapshot.favoriteCount
        if favoritesChanged { kinds.append(WidgetKind.favorites) }
        return kinds
    }

    /// Renews a playing snapshot before it expires, though nothing changed:
    /// the app still plays.
    func confirmPlaying() async {
        guard var snapshot = WidgetStorage.loadSnapshot(), snapshot.isPlaying
        else { return }
        snapshot.savedAt = Date()
        guard WidgetStorage.save(snapshot) else { return }
        await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Saves the widgets' snapshot as not playing, at once: for the app
    /// quitting, when there's no time to wait for Flutter.
    nonisolated static func markStopped() {
        guard var snapshot = WidgetStorage.loadSnapshot(), snapshot.isPlaying
        else { return }
        snapshot.isPlaying = false
        snapshot.savedAt = Date()
        if WidgetStorage.save(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

/// The widgets' images: station logos and song covers, downsized for the
/// widget and kept under a name drawn from their URL, so each is fetched
/// once.
enum WidgetImages {
    enum Kind {
        case logo
        case cover

        /// Enough for the largest place each shows on a 3x screen.
        var side: Int {
            switch self {
            case .logo: return 420
            case .cover: return 600
            }
        }

        /// Logos keep their transparency; covers are photos.
        var type: UTType {
            switch self {
            case .logo: return .png
            case .cover: return .jpeg
            }
        }
    }

    fileprivate static func file(
        for image: WidgetPayload.Image?,
        kind: Kind
    ) async -> String? {
        guard let image, let directory = WidgetStorage.imagesDirectory else {
            return nil
        }
        let name = fileName(for: image.url, kind: kind)
        let target = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return name }
        guard let data = await load(image),
              let square = squared(data, side: kind.side)
        else {
            NSLog("WidgetImages: couldn't load \(image.url)")
            return nil
        }
        return write(square, to: target, type: kind.type) ? name : nil
    }

    /// Deletes the images [snapshot] no longer shows.
    static func prune(keeping snapshot: WidgetSnapshot) {
        guard let directory = WidgetStorage.imagesDirectory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        let kept = Set(
            [snapshot.station?.logo, snapshot.cover].compactMap { $0 }
                + snapshot.favorites.compactMap(\.logo)
        )
        for file in files where !kept.contains(file) && !file.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    private static func fileName(for url: String, kind: Kind) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let fileExtension = kind.type.preferredFilenameExtension ?? "img"
        return "\(hex)-\(kind.side).\(fileExtension)"
    }

    /// The app's cached copy when there's one, else a download.
    private static func load(_ image: WidgetPayload.Image) async -> Data? {
        if let path = image.path, let data = FileManager.default.contents(atPath: path) {
            return data
        }
        guard let url = URL(string: image.url) else { return nil }
        do {
            let request = URLRequest(url: url, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// The middle square of the image, [side] pixels or the image's own
    /// size if smaller: what the widgets show of it, as the app does. Square
    /// on disk, since a tinted Home Screen ignores the widget's clipping and
    /// a wide cover spilled over its frame.
    private static func squared(_ data: Data, side: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? side
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? side
        // Large enough that the shorter side, which the square keeps, is
        // [side].
        let ratio = Double(max(width, height)) / Double(max(1, min(width, height)))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((Double(side) * ratio).rounded(.up)),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return nil }
        let square = min(image.width, image.height)
        return image.cropping(to: CGRect(
            x: (image.width - square) / 2,
            y: (image.height - square) / 2,
            width: square,
            height: square
        ))
    }

    /// Writes [image] under a temporary name first, so the widget never
    /// reads half a file.
    private static func write(_ image: CGImage, to url: URL, type: UTType) -> Bool {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Unique, since an overtaken save may still be writing the same
        // image.
        let partial = url.appendingPathExtension("\(UUID().uuidString).part")
        guard let destination = CGImageDestinationCreateWithURL(
            partial as CFURL, type.identifier as CFString, 1, nil
        ) else { return false }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            try? manager.removeItem(at: partial)
            return false
        }
        do {
            if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
            try manager.moveItem(at: partial, to: url)
            return true
        } catch {
            try? manager.removeItem(at: partial)
            return false
        }
    }
}
