import SwiftUI

/// Full-screen Now Playing — large artwork, station + song metadata,
/// recent song history, and a row of playback controls (play/pause,
/// like, dislike, favorite, share). Pressing menu/back returns to the
/// previous tab.
struct NowPlayingView: View {
    let station: Station
    let isFavorite: Bool
    @ObservedObject var player: AudioPlayer
    @ObservedObject var songHistory: SongHistoryStore

    let onBack: () -> Void
    let onToggleFavorite: () -> Void

    @State private var liked = false
    @State private var disliked = false
    @State private var lastTrackedSongId: String?
    @State private var isSharing = false

    var body: some View {
        ZStack {
            backgroundArtwork
            HStack(alignment: .top, spacing: Theme.Spacing.xxl) {
                artwork
                metadataAndControls
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.xl)

            if isSharing, let url = shareURL {
                ShareSheet(
                    stationTitle: station.title,
                    url: url,
                    onDismiss: { isSharing = false }
                )
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .onExitCommand {
            if isSharing { isSharing = false } else { onBack() }
        }
        .onChange(of: station.songTitle) { _, _ in
            // Reset like/dislike on song change — they're per-song.
            let key = "\(station.slug):\(station.songTitle)"
            if key != lastTrackedSongId {
                liked = false
                disliked = false
                lastTrackedSongId = key
            }
        }
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
        .frame(width: 460, height: 460)
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
            stationLine
            Text(displaySongTitle)
                .font(.system(size: 56, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            if !station.songArtist.isEmpty {
                Text(station.songArtist)
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textSecondary)
            }

            connectionLine

            controls
                .padding(.top, Theme.Spacing.lg)

            recentSongs
                .padding(.top, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stationLine: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(station.title.uppercased())
                .font(.system(size: 20, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.textSecondary)
            if let listeners = station.totalListeners, listeners > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "headphones")
                    Text("\(listeners)")
                }
                .font(.system(size: 18))
                .foregroundStyle(Theme.textTertiary)
            }
            if station.averageRating > 0 {
                RatingStars(
                    rating: station.averageRating,
                    count: station.reviews.count,
                    size: 16
                )
            }
        }
    }

    @ViewBuilder
    private var connectionLine: some View {
        if case .connecting = player.state {
            HStack(spacing: 8) {
                ProgressView()
                Text("Se conectează…")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, Theme.Spacing.sm)
        } else if case .failed(let message) = player.state {
            Text(message)
                .font(.system(size: 20))
                .foregroundStyle(Color.red.opacity(0.9))
                .padding(.top, Theme.Spacing.sm)
        }
    }

    private var displaySongTitle: String {
        station.songTitle.isEmpty ? station.title : station.songTitle
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Theme.Spacing.lg) {
            CircleControl(
                icon: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                tint: liked ? Theme.primary : Theme.textPrimary
            ) {
                liked.toggle()
                if liked { disliked = false }
            }
            CircleControl(icon: "play.fill", isPrimary: true,
                          systemPause: player.isPlaying) {
                player.togglePlayPause()
            }
            CircleControl(
                icon: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                tint: disliked ? Theme.primary : Theme.textPrimary
            ) {
                disliked.toggle()
                if disliked { liked = false }
            }
            CircleControl(
                icon: isFavorite ? "heart.fill" : "heart",
                tint: isFavorite ? Theme.primary : Theme.textPrimary
            ) {
                onToggleFavorite()
            }
            shareButton
        }
    }

    private var shareURL: URL? {
        URL(string: "https://www.radiocrestin.ro/radio/\(station.slug)")
    }

    @ViewBuilder
    private var shareButton: some View {
        if shareURL != nil {
            CircleControl(icon: "square.and.arrow.up") {
                isSharing = true
            }
        }
    }

    // MARK: - Recent songs

    @ViewBuilder
    private var recentSongs: some View {
        let entries = songHistory.entries(for: station.slug)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Melodii recente")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                ForEach(entries.prefix(4)) { entry in
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "music.note")
                            .foregroundStyle(Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            if !entry.artist.isEmpty {
                                Text(entry.artist)
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(timeAgo(entry.timestamp))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "acum" }
        let minutes = seconds / 60
        if minutes < 60 { return "acum \(minutes) min" }
        let hours = minutes / 60
        return "acum \(hours)h"
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
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(isPrimary ? .white : tint)
                .frame(width: 80, height: 80)
                .background(
                    Circle().fill(isPrimary ? Theme.primary : Theme.surfaceVariant)
                )
        }
        .buttonStyle(.card)
    }
}
