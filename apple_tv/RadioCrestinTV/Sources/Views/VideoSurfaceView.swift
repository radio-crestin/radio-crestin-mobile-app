import AVFoundation
import SwiftUI
import UIKit

/// A bare video surface backed by an `AVPlayerLayer` bound to the shared
/// `AVPlayer`. We deliberately avoid `AVKit`'s `VideoPlayer` /
/// `AVPlayerViewController` so tvOS doesn't draw its own transport controls
/// on top — `NowPlayingView` renders a custom, brand-styled overlay instead.
///
/// `videoGravity` is `.resizeAspect` so 16:9 (or any) content is letter-/
/// pillar-boxed rather than cropped — nothing important gets cut off on a
/// 10-foot screen.
struct VideoSurfaceView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        // Re-bind only when the player instance actually changes to avoid
        // interrupting playback on every SwiftUI update pass.
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    /// UIView whose backing layer *is* the `AVPlayerLayer`, so it resizes
    /// with the view automatically (no manual frame bookkeeping).
    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        // swiftlint:disable:next force_cast
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
