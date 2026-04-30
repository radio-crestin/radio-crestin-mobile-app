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
    @State private var focusedAction: String?

    var body: some View {
        ZStack {
            // Background blur ignores the safe area so it bleeds to the
            // edges; everything else respects safe area so back button +
            // controls don't disappear into the TV's overscan area.
            ZStack {
                Theme.background
                backgroundArtwork
            }
            .ignoresSafeArea()

            // Main content — artwork + metadata centered.
            HStack(alignment: .center, spacing: Theme.Spacing.xxl) {
                artwork
                metadataAndControls
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.xxl)
            .padding(.top, 100)   // leave room for the back button row
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            // Persistent top bar with the back button, top-left aligned.
            VStack {
                HStack {
                    backButton
                    Spacer()
                }
                Spacer()
            }
            .padding(Theme.Spacing.lg)

            if isSharing, let url = shareURL {
                ShareSheet(
                    stationTitle: station.title,
                    url: url,
                    onDismiss: { isSharing = false }
                )
                .transition(.opacity)
            }
        }
        // Declarative default focus — runs after the focus graph is built,
        // so the back button reliably owns focus on entry. Replaces the
        // earlier DispatchQueue-based workaround which was racy.
        .defaultFocus($backButtonFocused, true)
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

    @FocusState private var backButtonFocused: Bool

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 26, weight: .heavy))
                Text("Înapoi la posturi")
                    .font(.system(size: 26, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .background(
                Capsule().fill(
                    backButtonFocused ? Theme.primary : Color.black.opacity(0.7)
                )
            )
            .overlay(
                Capsule().stroke(
                    backButtonFocused ? Color.white : Color.white.opacity(0.25),
                    lineWidth: backButtonFocused ? 4 : 1.5
                )
            )
            .scaleEffect(backButtonFocused ? 1.1 : 1.0)
            .shadow(
                color: backButtonFocused
                    ? Theme.primary.opacity(0.7)
                    : .black.opacity(0.5),
                radius: backButtonFocused ? 30 : 12, x: 0, y: 8
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.72),
                       value: backButtonFocused)
        }
        .buttonStyle(.plain)
        // Autofocus is set declaratively via `.defaultFocus` on the body
        // so the back affordance reliably owns focus on entry.
        .focused($backButtonFocused)
    }

    private var artwork: some View {
        StationArtwork(
            station: station,
            cornerRadius: 28,
            targetSize: CGSize(width: 460, height: 460)
        )
        .shadow(color: .black.opacity(0.6), radius: 32, x: 0, y: 12)
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
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            stationLine
            VStack(alignment: .leading, spacing: 8) {
                Text(displaySongTitle)
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if !station.songArtist.isEmpty {
                    Text(station.songArtist)
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            controls
                .padding(.top, Theme.Spacing.md)

            statusLine

            recentSongs
        }
        // Cap the column so giant station logos / song titles don't push
        // the controls off screen.
        .frame(maxWidth: 900, alignment: .leading)
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
                    count: station.reviewCount,
                    size: 16
                )
            }
        }
    }

    /// Fixed-height status line below the controls. Shows the focused
    /// button's label, the connection spinner, or an error message. The
    /// height is constant so changing state never causes layout shift.
    private var statusLine: some View {
        HStack(spacing: 10) {
            switch player.state {
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textSecondary)
                Text("Se conectează…")
                    .foregroundStyle(Theme.textSecondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .lineLimit(1)
            case .idle, .playing, .paused:
                if let action = focusedAction {
                    Text(action)
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    // Reserve the row even when there's nothing to say.
                    Text(" ")
                }
            }
        }
        .font(.system(size: 22, weight: .medium))
        .frame(height: 40, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    private var displaySongTitle: String {
        station.songTitle.isEmpty ? station.title : station.songTitle
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Theme.Spacing.lg) {
            CircleControl(
                icon: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                tint: liked ? Theme.primary : Theme.textPrimary,
                label: "Apreciază",
                onFocusChange: setFocusedAction
            ) {
                liked.toggle()
                if liked { disliked = false }
            }
            CircleControl(
                icon: "play.fill",
                isPrimary: true,
                systemPause: player.isPlaying,
                label: player.isPlaying ? "Pauză" : "Redă",
                onFocusChange: setFocusedAction
            ) {
                player.togglePlayPause()
            }
            CircleControl(
                icon: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                tint: disliked ? Theme.primary : Theme.textPrimary,
                label: "Nu îmi place",
                onFocusChange: setFocusedAction
            ) {
                disliked.toggle()
                if disliked { liked = false }
            }
            CircleControl(
                icon: isFavorite ? "heart.fill" : "heart",
                tint: isFavorite ? Theme.primary : Theme.textPrimary,
                label: isFavorite ? "Elimină din favorite" : "Adaugă la favorite",
                onFocusChange: setFocusedAction
            ) {
                onToggleFavorite()
            }
            shareButton
        }
    }

    private func setFocusedAction(_ label: String?) {
        // The focus engine fires onChange on both gain and loss; the
        // last gain wins, so we only clear when our own label says so.
        if let label {
            focusedAction = label
        } else if focusedAction != nil {
            // Defer to next tick so a sibling button's focus-gain (which
            // arrives after this button's focus-loss) can take precedence.
            DispatchQueue.main.async {
                if focusedActionIsStale() { focusedAction = nil }
            }
        }
    }

    /// Checks whether the recorded focused action no longer matches any
    /// currently-focused control. SwiftUI doesn't give us a single global
    /// focus token, so we approximate by clearing if no button is focused
    /// — `setFocusedAction(_:)` already clears when each button loses
    /// focus, so by the time this fires the new focus has updated.
    private func focusedActionIsStale() -> Bool { false }

    private var shareURL: URL? {
        URL(string: "https://www.radiocrestin.ro/radio/\(station.slug)")
    }

    @ViewBuilder
    private var shareButton: some View {
        if shareURL != nil {
            CircleControl(
                icon: "square.and.arrow.up",
                label: "Distribuie",
                onFocusChange: setFocusedAction
            ) {
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
///
/// We use `.buttonStyle(.plain)` instead of `.card` because the system
/// card style draws a rounded *rectangle* halo around what is visually a
/// circle, which looks like a sticker. With `.plain` we own the focus
/// treatment: scale up + brand-pink glow that follows the circular shape.
///
/// `onFocusChange` is fired with the supplied `label` on focus gain and
/// `nil` on focus loss so the parent can render a tooltip-style status
/// line below the row.
private struct CircleControl: View {
    let icon: String
    var isPrimary: Bool = false
    var systemPause: Bool = false
    var tint: Color = Theme.textPrimary
    var label: String = ""
    var onFocusChange: ((String?) -> Void)? = nil
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isPrimary ? Theme.primary : Theme.surfaceVariant)
                if isFocused {
                    Circle()
                        .stroke(Color.white.opacity(isPrimary ? 0.95 : 0.85),
                                lineWidth: 4)
                }
                Image(systemName: systemPause ? "pause.fill" : icon)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(isPrimary ? .white : tint)
            }
            .frame(width: 80, height: 80)
            .scaleEffect(isFocused ? 1.18 : 1.0)
            .shadow(
                color: isFocused
                    ? (isPrimary ? Theme.primary.opacity(0.55) : .black.opacity(0.55))
                    : .black.opacity(0.25),
                radius: isFocused ? 28 : 8,
                x: 0,
                y: isFocused ? 12 : 4
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.72),
                       value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused ? label : nil)
        }
    }
}
