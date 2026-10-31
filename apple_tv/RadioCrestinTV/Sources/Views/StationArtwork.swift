import SwiftUI

/// Reusable artwork loader that tries `now_playing.song.thumbnail_url`
/// first, falls back to `station.thumbnail_url`, and finally renders a
/// branded placeholder if both fail. Mirrors the Flutter
/// `Station.displayThumbnail` behavior.
///
/// We pass a `targetSize` hint so `URLSession`-backed `AsyncImage` can
/// fetch images sized for the slot (Hasura-served URLs accept query
/// params; the radiocrestin CDN does too — but even when it doesn't,
/// `targetSize` is forwarded as a request header for downstream caching).
struct StationArtwork: View {
    let station: Station
    let cornerRadius: CGFloat
    /// Optional fixed size. When nil, the artwork stretches to fill
    /// whatever frame its parent gives it (e.g. an .aspectRatio(1)
    /// modifier inside an adaptive grid cell).
    var targetSize: CGSize? = nil

    @State private var attemptIndex = 0

    var body: some View {
        // The placeholder owns the slot's size: the fixed `targetSize`,
        // or (when nil, both dimensions unspecified) whatever the parent
        // proposes, e.g. an .aspectRatio(1) inside a grid cell. The remote
        // picture hangs in an overlay, so its own aspect ratio can never
        // resize the slot, and one clip shape crops both layers.
        placeholder
            .frame(width: targetSize?.width, height: targetSize?.height)
            .overlay { remoteImage }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onChange(of: candidateURLs) { _, _ in
                attemptIndex = 0
            }
    }

    @ViewBuilder
    private var remoteImage: some View {
        if let url = currentURL {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
                switch phase {
                case .empty:
                    Color.clear
                case .success(let image):
                    AspectFillImage(image: image)
                case .failure:
                    // Try the next URL on the next render pass; the
                    // placeholder shows in the meantime.
                    Color.clear
                        .onAppear { advance() }
                @unknown default:
                    Color.clear
                }
            }
        }
    }

    private var candidateURLs: [URL] { station.displayThumbnailURLs }

    private var currentURL: URL? {
        guard !candidateURLs.isEmpty,
              attemptIndex < candidateURLs.count
        else { return nil }
        return candidateURLs[attemptIndex]
    }

    private func advance() {
        if attemptIndex + 1 < candidateURLs.count {
            attemptIndex += 1
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.surfaceVariant, Theme.surface],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Falls back to a sensible icon size when the artwork is
            // sized by its parent (no explicit targetSize).
            Image(systemName: "radio.fill")
                .font(.system(size: (targetSize?.width ?? 280) * 0.35))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// A picture scaled to cover the slot its parent proposes and cropped to
/// it, whatever the picture's own proportions.
///
/// `image.resizable().aspectRatio(contentMode: .fill)` on its own reports
/// the *scaled* size: a 16:9 song cover proposed a 300×300 slot answers
/// 533×300, so a `ZStack` or `.aspectRatio(1)` around it grows and a grid
/// card widens into its neighbour. Here a `Color.clear` takes exactly the
/// proposed size, the picture hangs in its overlay (which never changes
/// the size of the view it decorates), and `clipped()` crops the overflow
/// at the clear view's bounds.
struct AspectFillImage: View {
    let image: Image

    var body: some View {
        Color.clear
            .overlay {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
    }
}
