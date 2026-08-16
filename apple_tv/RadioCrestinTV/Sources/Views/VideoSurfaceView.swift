import AVFoundation
import SwiftUI
import UIKit

/// A bare video surface backed by an `AVPlayerLayer` bound to the shared
/// `AVPlayer`. We deliberately avoid `AVKit`'s `VideoPlayer` /
/// `AVPlayerViewController` so tvOS doesn't draw its own transport controls
/// on top — `NowPlayingView` renders a custom, brand-styled overlay instead.
///
/// Because there is no `AVPlayerViewController`, there is also no system
/// loading spinner and no system controls auto-hide: both are the app's
/// responsibility. `onReadyForDisplayChange` reports the exact moment the
/// layer has real picture to draw, which is what closes the "black
/// rectangle with no feedback" gap — `AVPlayerItem.status == .readyToPlay`
/// fires earlier, before the first frame has decoded.
///
/// `videoGravity` is `.resizeAspect` so 16:9 (or any) content is letter-/
/// pillar-boxed rather than cropped — nothing important gets cut off on a
/// 10-foot screen.
struct VideoSurfaceView: UIViewRepresentable {
    let player: AVPlayer

    /// Called on the main actor whenever the layer flips between "has a
    /// frame to show" and "has nothing yet" (including on item swaps).
    var onReadyForDisplayChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onReadyForDisplayChange)
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        context.coordinator.observe(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        context.coordinator.onChange = onReadyForDisplayChange
        // Re-bind only when the player instance actually changes to avoid
        // interrupting playback on every SwiftUI update pass.
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    static func dismantleUIView(
        _ uiView: PlayerLayerView, coordinator: Coordinator
    ) {
        coordinator.invalidate()
    }

    /// Owns the `isReadyForDisplay` observation for the lifetime of the
    /// representable. Held by SwiftUI, so the KVO token outlives a single
    /// update pass without leaking.
    final class Coordinator {
        var onChange: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?

        init(onChange: ((Bool) -> Void)?) {
            self.onChange = onChange
        }

        func observe(_ layer: AVPlayerLayer) {
            observation = layer.observe(
                \.isReadyForDisplay, options: [.initial, .new]
            ) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor in
                    self?.onChange?(ready)
                }
            }
        }

        func invalidate() {
            observation?.invalidate()
            observation = nil
        }

        deinit { observation?.invalidate() }
    }

    /// UIView whose backing layer *is* the `AVPlayerLayer`, so it resizes
    /// with the view automatically (no manual frame bookkeeping).
    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        // swiftlint:disable:next force_cast
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
