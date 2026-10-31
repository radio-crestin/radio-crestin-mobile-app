import Foundation
import Network

/// Reports the moment the device's network path becomes usable again, so
/// the audio engine retries a station at once instead of waiting out its
/// backoff, and the moment it moves to another network interface while it
/// stays usable, so connections left on the old one are not waited on.
///
/// `NWPathMonitor` is event-driven: nothing runs between path changes.
@MainActor
final class NetworkPathWatcher {
    /// What a path update means for the engine.
    enum Event: Equatable {
        /// The path went from unusable to usable.
        case restored
        /// The path stayed usable but its traffic moved to another
        /// interface (an Ethernet cable plugged in or out while on Wi-Fi):
        /// connections on the interface it left may hang until they time
        /// out.
        case changed
    }

    /// The path, reduced to what the watcher compares.
    struct Path: Equatable {
        var isSatisfied: Bool
        /// The interface traffic goes out on: the first available one, in
        /// the system's order of preference.
        var interface: String?
    }

    /// Called on the main actor when the path goes from unusable to usable.
    var onRestored: (() -> Void)?

    /// Called on the main actor when the path stays usable on another
    /// interface.
    var onChanged: (() -> Void)?

    /// Whether the path is usable; nil until the monitor's first report.
    var isSatisfied: Bool? { path?.isSatisfied }

    private let monitor = NWPathMonitor()
    /// The path at the last report; nil until the first, so the first
    /// report (the path as it is at launch) is neither a restore nor a
    /// change.
    private var path: Path?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let current = Path(
                isSatisfied: path.status == .satisfied,
                interface: path.availableInterfaces.first?.name
            )
            Task { @MainActor in self?.update(current) }
        }
        monitor.start(
            queue: DispatchQueue(label: "ro.radiocrestin.tv.network-path")
        )
    }

    deinit {
        monitor.cancel()
    }

    /// What going from `old` to `new` means; nil for nothing to report.
    /// Pure, for tests.
    static func event(from old: Path?, to new: Path) -> Event? {
        guard let old, new.isSatisfied else { return nil }
        guard old.isSatisfied else { return .restored }
        return old.interface == new.interface ? nil : .changed
    }

    private func update(_ new: Path) {
        let event = Self.event(from: path, to: new)
        path = new
        switch event {
        case .restored: onRestored?()
        case .changed: onChanged?()
        case nil: break
        }
    }
}
