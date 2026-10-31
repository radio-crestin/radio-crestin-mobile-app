import Foundation
import Network

/// Reports the moment the device's network path becomes usable again, so
/// the audio engine retries a station at once instead of waiting out its
/// backoff.
///
/// `NWPathMonitor` is event-driven: nothing runs between path changes.
@MainActor
final class NetworkPathWatcher {
    /// Called on the main actor when the path goes from unusable to usable.
    var onRestored: (() -> Void)?

    private let monitor = NWPathMonitor()
    /// Last known state; nil until the monitor's first report, so the
    /// first report (the path as it is at launch) is never a "restore".
    private var isSatisfied: Bool?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.update(isSatisfied: satisfied) }
        }
        monitor.start(
            queue: DispatchQueue(label: "ro.radiocrestin.tv.network-path")
        )
    }

    deinit {
        monitor.cancel()
    }

    private func update(isSatisfied satisfied: Bool) {
        let wasSatisfied = isSatisfied
        isSatisfied = satisfied
        if satisfied, wasSatisfied == false {
            onRestored?()
        }
    }
}
