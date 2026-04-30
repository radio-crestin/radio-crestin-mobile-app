import SwiftUI

/// Single station tile used in the Stations / Favorite / Recente grids.
///
/// SwiftUI on tvOS already renders a focus halo around `.cardButtonStyle()`
/// so we lean on the platform — adding a custom border on top fights the
/// system focus engine and looks bolted-on. We do add a brand-pink dot for
/// the "currently playing" indicator so users can spot the active station.
struct StationCard: View {
    let station: Station
    let isPlaying: Bool
    let isFavorite: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ZStack(alignment: .topTrailing) {
                    artwork
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.primary)
                            .padding(8)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(8)
                    }
                    if isPlaying {
                        playingBadge
                            .padding(8)
                    }
                }
                Text(station.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !station.songTitle.isEmpty {
                    Text(station.songTitle)
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 280)
            .contentShape(Rectangle())
        }
        .buttonStyle(.card)
    }

    private var artwork: some View {
        StationArtwork(
            station: station,
            cornerRadius: Theme.Radius.lg,
            targetSize: CGSize(width: 280, height: 280)
        )
    }

    private var playingBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .bold))
            Text("LIVE")
                .font(.system(size: 14, weight: .heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.primary, in: Capsule())
    }
}
