import SwiftUI

/// Reusable artwork loader that tries `now_playing.song.thumbnail_url`
/// first, falls back to `station.thumbnail_url`, and finally renders a
/// branded placeholder if both fail. Mirrors the Flutter
/// `Station.displayThumbnail` behavior.
///
/// Pictures are asked of the CDN at the slot's size in pixels (see
/// `ArtworkURL`) and come through `ArtworkLoader`, which keeps them in
/// memory: a card scrolled back into view shows its picture on the first
/// frame.
struct StationArtwork: View {
    let station: Station
    let cornerRadius: CGFloat
    /// Optional fixed size. When nil, the artwork stretches to fill
    /// whatever frame its parent gives it (e.g. an .aspectRatio(1)
    /// modifier inside an adaptive grid cell).
    var targetSize: CGSize? = nil
    /// How much larger than its slot the artwork is drawn when focused,
    /// e.g. the lift of a `.card` button: the picture is asked for at that
    /// size, so it stays sharp while focused.
    var focusScale: CGFloat = 1

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // The placeholder owns the slot's size: the fixed `targetSize`,
        // or (when nil, both dimensions unspecified) whatever the parent
        // proposes, e.g. an .aspectRatio(1) inside a grid cell. The remote
        // picture hangs in an overlay, so its own aspect ratio can never
        // resize the slot, and one clip shape crops both layers.
        placeholder
            .frame(width: targetSize?.width, height: targetSize?.height)
            .overlay {
                // The slot's laid-out width picks the size asked of the CDN.
                GeometryReader { geometry in
                    ArtworkImage(
                        urls: Self.urls(
                            for: station,
                            width: geometry.size.width * focusScale,
                            scale: displayScale
                        )
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// The picture URLs, in order of preference, that the artwork of
    /// `station` asks for in a slot `width` points wide. A view that wants
    /// the same picture (Now Playing's backdrop) asks for these too and
    /// gets it from memory.
    static func urls(
        for station: Station,
        width: CGFloat,
        scale: CGFloat
    ) -> [URL] {
        ArtworkURL.sized(
            station.displayThumbnailURLs,
            points: width,
            scale: scale
        )
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
        // Decorative, like the picture over it: VoiceOver read it as
        // "Radio With Antenna, Filled" next to Now Playing's title.
        .accessibilityHidden(true)
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
