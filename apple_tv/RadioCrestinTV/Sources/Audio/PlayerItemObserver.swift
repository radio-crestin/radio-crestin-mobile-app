import AVFoundation
import Combine

/// Reports what happens to one `AVPlayerItem` on the main actor, until it
/// is cancelled or released.
///
/// The engine gives every live attempt and playlist entry its own observer
/// and cancels it before loading the next item. Callbacks AVFoundation had
/// already queued for the replaced item are then dropped instead of acting
/// on the item that replaced it.
@MainActor
final class PlayerItemObserver {
    enum Event {
        case readyToPlay
        /// `status == .failed`.
        case failed(Error?)
        /// `AVPlayerItemDidPlayToEndTime`: a file finished, or the server
        /// closed a live stream.
        case playedToEnd
        /// `AVPlayerItemFailedToPlayToEndTime`: playback broke off. When an
        /// HLS origin goes away this is the only signal: `status` stays
        /// `readyToPlay`.
        case failedToPlayToEnd(Error?)
    }

    private let onEvent: @MainActor (Event) -> Void
    private var statusObservation: NSKeyValueObservation?
    private var subscriptions: Set<AnyCancellable> = []
    private var isCancelled = false

    init(item: AVPlayerItem, onEvent: @escaping @MainActor (Event) -> Void) {
        self.onEvent = onEvent
        // `status` is KVO-only. It is read on the main actor after the hop,
        // like the item's other state.
        statusObservation = item.observe(\.status, options: [.new]) {
            [weak self] item, _ in
            Task { @MainActor in self?.statusChanged(of: item) }
        }
        let center = NotificationCenter.default
        center.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .sink { [weak self] _ in
                Task { @MainActor in self?.deliver(.playedToEnd) }
            }
            .store(in: &subscriptions)
        center.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .sink { [weak self] note in
                let error = note.userInfo?[
                    AVPlayerItemFailedToPlayToEndTimeErrorKey
                ] as? Error
                Task { @MainActor in self?.deliver(.failedToPlayToEnd(error)) }
            }
            .store(in: &subscriptions)
    }

    /// Stops observing; events already on their way are dropped.
    func cancel() {
        isCancelled = true
        statusObservation?.invalidate()
        statusObservation = nil
        subscriptions.removeAll()
    }

    private func statusChanged(of item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            deliver(.readyToPlay)
        case .failed:
            deliver(.failed(item.error))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func deliver(_ event: Event) {
        guard !isCancelled else { return }
        onEvent(event)
    }
}
