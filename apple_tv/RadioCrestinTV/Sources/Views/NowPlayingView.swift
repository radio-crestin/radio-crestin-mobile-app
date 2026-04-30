import SwiftUI

/// Full-screen Now Playing — large artwork, station + song metadata,
/// and a row of playback controls. Pressing the Siri Remote menu/back
/// returns the user to the previous tab via the navigation stack.
struct NowPlayingView: View {
    let station: Station
    let isFavorite: Bool
    @ObservedObject var player: AudioPlayer

    let onBack: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        ZStack {
            backgroundArtwork
            HStack(spacing: Theme.Spacing.xxl) {
                artwork
                metadataAndControls
            }
            .padding(.horizontal, Theme.Spacing.xxl)
        }
        .ignoresSafeArea()
        .onExitCommand(perform: onBack)
    }

    // MARK: - Artwork

    private var artwork: some View {
        Group {
            if let urlString = station.thumbnailUrl,
               let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        artworkPlaceholder
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: 540, height: 540)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.6), radius: 32, x: 0, y: 12)
    }

    private var artworkPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.primary, Theme.primaryDark],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "radio.fill")
                .font(.system(size: 160))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var backgroundArtwork: some View {
        Group {
            if let urlString = station.thumbnailUrl,
               let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Theme.background
                    }
                }
            } else {
                Theme.background
            }
        }
        .blur(radius: 60)
        .overlay(Color.black.opacity(0.65))
    }

    // MARK: - Right column

    private var metadataAndControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Text(station.title.uppercased())
                    .font(.system(size: 22, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.textSecondary)
                if let listeners = station.totalListeners, listeners > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "headphones")
                        Text("\(listeners)")
                    }
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textTertiary)
                }
            }

            Text(displaySongTitle)
                .font(.system(size: 64, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)

            if !station.songArtist.isEmpty {
                Text(station.songArtist)
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.textSecondary)
            }

            if case .connecting = player.state {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Se conectează…")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, Theme.Spacing.sm)
            }

            if case .failed(let message) = player.state {
                Text(message)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .padding(.top, Theme.Spacing.sm)
            }

            controls.padding(.top, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displaySongTitle: String {
        station.songTitle.isEmpty ? station.title : station.songTitle
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Theme.Spacing.lg) {
            CircleControl(icon: "play.fill", isPrimary: true,
                          systemPause: player.isPlaying) {
                player.togglePlayPause()
            }
            CircleControl(
                icon: isFavorite ? "heart.fill" : "heart",
                tint: isFavorite ? Theme.primary : Theme.textPrimary
            ) {
                onToggleFavorite()
            }
        }
    }
}

/// Circular focusable control. The play button doubles up as pause when
/// `systemPause` is true — keeps the focused element stable across state.
private struct CircleControl: View {
    let icon: String
    var isPrimary: Bool = false
    var systemPause: Bool = false
    var tint: Color = Theme.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemPause ? "pause.fill" : icon)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(isPrimary ? .white : tint)
                .frame(width: 80, height: 80)
                .background(
                    Circle().fill(isPrimary ? Theme.primary : Theme.surfaceVariant)
                )
        }
        .buttonStyle(.card)
    }
}
