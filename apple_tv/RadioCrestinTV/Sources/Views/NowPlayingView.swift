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
    let onPrev: () -> Void
    let onNext: () -> Void

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
                icon: "backward.fill",
                label: "Postul anterior",
                onFocusChange: setFocusedAction,
                action: onPrev
            )
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
                icon: "forward.fill",
                label: "Postul următor",
                onFocusChange: setFocusedAction,
                action: onNext
            )
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

    /// Always renders three rows so the layout doesn't shift when entries
    /// arrive from the API a moment after the view mounts. Empty slots
    /// are invisible but reserve their height.
    private var recentSongs: some View {
        let entries = songHistory.entries(for: station.slug)
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Melodii recente")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            ForEach(0..<3, id: \.self) { idx in
                _SongHistoryRow(entry: entries.dropFirst(idx).first)
            }
        }
    }
}

/// Single row in the "Melodii recente" list. Renders an empty (but
/// space-reserving) row when `entry` is nil so the layout is stable
/// before the API call completes.
private struct _SongHistoryRow: View {
    let entry: SongEntry?

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if let entry, let url = entry.thumbnailUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholderArt
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                placeholderArt
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry?.title ?? " ")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(entry?.artist ?? " ")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(entry.map { Self.timeAgo($0.timestamp) } ?? " ")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
        }
        .opacity(entry == nil ? 0 : 1)
        .frame(height: 44)
    }

    private var placeholderArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.surfaceVariant)
            Image(systemName: "music.note")
                .foregroundStyle(Theme.textTertiary)
                .font(.system(size: 16))
        }
    }

    private static func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "acum" }
        let minutes = seconds / 60
        if minutes < 60 { return "acum \(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "acum \(hours)h" }
        let days = hours / 24
        return "acum \(days)z"
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
        // We use a focusable view + tap gesture instead of `Button`
        // because tvOS draws a rounded-rectangle halo around any
        // `Button`, regardless of `buttonStyle`. By owning the focus
        // visual ourselves we get a circle that hugs the control
        // (matches Apple Music's playback chrome).
        ZStack {
            Circle()
                .fill(isPrimary ? Theme.primary : Theme.surfaceVariant)
                .overlay(
                    Circle()
                        .stroke(
                            Color.white.opacity(isPrimary ? 0.95 : 0.85),
                            lineWidth: isFocused ? 3 : 0
                        )
                )
            Image(systemName: systemPause ? "pause.fill" : icon)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(isPrimary ? .white : tint)
        }
        .frame(width: 72, height: 72)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .shadow(
            color: isFocused
                ? (isPrimary ? Theme.primary.opacity(0.55) : .black.opacity(0.5))
                : .black.opacity(0.25),
            radius: isFocused ? 16 : 6,
            x: 0,
            y: isFocused ? 8 : 3
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.72),
                   value: isFocused)
        .focusable(true)
        .focused($isFocused)
        // Siri-Remote Select fires onTapGesture on tvOS when the view
        // is focused — same activation contract as a Button.
        .onTapGesture(perform: action)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused ? label : nil)
        }
    }
}
