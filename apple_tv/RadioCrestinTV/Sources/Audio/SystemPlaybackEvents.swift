import AVFoundation
import Combine

/// Reports when the system, not the listener, stops the app's audio.
///
/// AVPlayer pauses itself for an audio interruption, when the output in use
/// goes away, and for video when the app goes to the background. Without
/// these events the engine would see a listener who wants audio and none
/// coming, take it for a failed stream and reload it behind the system's
/// back; with them it marks the station paused, as the listener would.
@MainActor
final class SystemPlaybackEvents {
    enum Event: Equatable {
        /// Another audio session took over: Siri, a call, another app.
        case interruptionBegan
        /// The interruption is over; `shouldResume` is the system's hint
        /// that playback interrupted by it should continue.
        case interruptionEnded(shouldResume: Bool)
        /// The output in use went away (headphones, a HomePod switched
        /// off). Playback pauses, as on every Apple device.
        case outputLost
        /// tvOS paused a video item because the app went to the background.
        case pausedInBackground
    }

    private var subscriptions: Set<AnyCancellable> = []

    init(player: AVPlayer, onEvent: @escaping @MainActor (Event) -> Void) {
        let center = NotificationCenter.default
        // Audio session notifications arrive on a background thread; the
        // main queue puts them in order with the player's own changes.
        Publishers.Merge3(
            center.publisher(for: AVAudioSession.interruptionNotification),
            center.publisher(for: AVAudioSession.routeChangeNotification),
            center.publisher(
                for: AVPlayer.rateDidChangeNotification, object: player
            )
        )
        .receive(on: DispatchQueue.main)
        .sink { note in
            MainActor.assumeIsolated {
                if let event = Self.event(from: note) { onEvent(event) }
            }
        }
        .store(in: &subscriptions)
    }

    /// The event a system notification stands for, or nil when it does
    /// not concern the engine (e.g. a new output device was added, or the
    /// app itself changed the rate).
    static func event(from note: Notification) -> Event? {
        let info = note.userInfo
        switch note.name {
        case AVAudioSession.interruptionNotification:
            return interruptionEvent(info)
        case AVAudioSession.routeChangeNotification:
            guard let raw = info?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw)
                    == .oldDeviceUnavailable
            else { return nil }
            return .outputLost
        case AVPlayer.rateDidChangeNotification:
            guard let raw = info?[AVPlayer.rateDidChangeReasonKey] as? String,
                  AVPlayer.RateDidChangeReason(rawValue: raw)
                    == .appBackgrounded
            else { return nil }
            return .pausedInBackground
        default:
            return nil
        }
    }

    private static func interruptionEvent(
        _ info: [AnyHashable: Any]?
    ) -> Event? {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return nil }
        switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt
                    ?? 0
            )
            return .interruptionEnded(
                shouldResume: options.contains(.shouldResume)
            )
        @unknown default:
            return nil
        }
    }
}
