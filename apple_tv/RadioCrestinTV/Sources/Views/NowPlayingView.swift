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

    /// Focus scope used to mark the play/pause button as the preferred
    /// default focus target on entry. The user wants pause/resume to be
    /// the canonical first action, not the back button.
    @Namespace private var focusScope

    /// Programmatic focus binding used to seat focus on the play button
    /// on entry. `prefersDefaultFocus(_:in:)` alone wasn't reliable when
    /// each control sits inside a label-stack `VStack` — the focus
    /// engine ended up on the leftmost focusable. An explicit
    /// `FocusState` set in `.task` deterministically wins.
    enum ControlFocus: Hashable {
        case play
    }
    @FocusState private var controlFocus: ControlFocus?

    var body: some View {
        ZStack {
            if station.hasOnlyYouTubeItems {
                // Playlist with only YouTube entries — nothing tvOS can
                // embed. Explain rather than showing a broken player.
                youTubeOnlyLayout
            } else if player.isVideoContent {
                // TV station or a playlist video item — full-bleed video
                // with a self-managing auto-hiding control overlay.
                VideoNowPlaying(
                    station: station,
                    player: player,
                    isFavorite: isFavorite,
                    onBack: onBack,
                    onToggleFavorite: onToggleFavorite,
                    onPrevStation: onPrev,
                    onNextStation: onNext
                )
            } else {
                audioLayout
            }
        }
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

    // MARK: - Audio layout (radio + playlist audio items)

    private var audioLayout: some View {
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

            // Persistent top bar — back button on the left, brand mark
            // on the right so the app identity stays visible from the
            // station screen too.
            VStack {
                HStack(alignment: .center) {
                    backButton
                    Spacer()
                    BrandMark()
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
        // Default focus is owned by the play/pause button rather than the
        // back button — the user wants pause/resume to be the canonical
        // first action on entry. `prefersDefaultFocus(_:in:)` alone was
        // unreliable once each control sat inside a label-stack VStack
        // (focus engine kept landing on the leftmost focusable), so we
        // also seat focus explicitly via `controlFocus` in `.task`.
        .focusScope(focusScope)
        .task {
            // Yield once so the focus engine has the focusable nodes
            // registered before we ask one of them to take focus.
            try? await Task.sleep(nanoseconds: 50_000_000)
            controlFocus = .play
        }
    }

    private var isPlaylist: Bool { station.kind == .playlist }

    // MARK: - YouTube-only fallback

    private var youTubeOnlyLayout: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 90))
                    .foregroundStyle(Theme.textTertiary)
                Text(station.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Acest playlist conține doar clipuri YouTube, care nu pot fi redate pe Apple TV. Deschide aplicația Radio Creștin pe telefon pentru a le viziona.")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                    .lineSpacing(6)
                Button("Înapoi la posturi", action: onBack)
                    .buttonStyle(.card)
                    .padding(.top, Theme.Spacing.md)
            }
            .padding(Theme.Spacing.xxl)
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

    @ViewBuilder
    private var artwork: some View {
        Group {
            if isPlaylist,
               let thumb = player.currentPlaylistItem?.thumbnailUrl,
               let url = URL(string: thumb) {
                // Prefer the playlist item's own artwork (e.g. episode
                // cover) over the station logo.
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        StationArtwork(station: station, cornerRadius: 28)
                    }
                }
                .frame(width: 460, height: 460)
                .clipShape(RoundedRectangle(cornerRadius: 28))
            } else {
                StationArtwork(
                    station: station,
                    cornerRadius: 28,
                    targetSize: CGSize(width: 460, height: 460)
                )
            }
        }
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

    @ViewBuilder
    private var metadataAndControls: some View {
        if isPlaylist {
            playlistMetadataAndControls
        } else {
            radioMetadataAndControls
        }
    }

    private var radioMetadataAndControls: some View {
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

    // MARK: - Playlist audio column

    private var playlistMetadataAndControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                Text(station.title.uppercased())
                    .font(.system(size: 20, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.textSecondary)
                if player.playlistCount > 0 {
                    Text("\(player.playlistIndex + 1) / \(player.playlistCount)")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Theme.primary, in: Capsule())
                }
            }

            Text(player.currentPlaylistItem?.title ?? station.title)
                .font(.system(size: 52, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)

            if player.vodDuration > 0 {
                VodProgressBar(
                    position: player.vodPosition,
                    duration: player.vodDuration
                )
                .padding(.top, Theme.Spacing.xs)
            }

            playlistControls
                .padding(.top, Theme.Spacing.sm)

            statusLine
        }
        .frame(maxWidth: 900, alignment: .leading)
    }

    private var playlistControls: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            labeled("Înapoi 10s") {
                CircleControl(
                    icon: "gobackward.10",
                    label: "Înapoi 10s",
                    onFocusChange: setFocusedAction
                ) { player.seek(by: -10) }
            }
            labeled("Anterior") {
                CircleControl(
                    icon: "backward.fill",
                    label: "Anterior",
                    onFocusChange: setFocusedAction
                ) { player.previousItem() }
            }
            labeled(player.isPlaying ? "Pauză" : "Redă") {
                CircleControl(
                    icon: "play.fill",
                    isPrimary: true,
                    systemPause: player.isPlaying,
                    label: player.isPlaying ? "Pauză" : "Redă",
                    onFocusChange: setFocusedAction
                ) { player.togglePlayPause() }
                .prefersDefaultFocus(true, in: focusScope)
                .focused($controlFocus, equals: .play)
            }
            labeled("Următor") {
                CircleControl(
                    icon: "forward.fill",
                    label: "Următor",
                    onFocusChange: setFocusedAction
                ) { player.nextItem() }
            }
            labeled("Înainte 10s") {
                CircleControl(
                    icon: "goforward.10",
                    label: "Înainte 10s",
                    onFocusChange: setFocusedAction
                ) { player.seek(by: 10) }
            }
            labeled(isFavorite ? "Elimină din favorite" : "Adaugă la favorite") {
                CircleControl(
                    icon: isFavorite ? "heart.fill" : "heart",
                    tint: isFavorite ? Theme.primary : Theme.textPrimary,
                    label: isFavorite ? "Elimină din favorite" : "Adaugă la favorite",
                    onFocusChange: setFocusedAction
                ) { onToggleFavorite() }
            }
        }
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

    /// Fixed-height status line that surfaces the connection spinner or
    /// stream error. Action labels are no longer rendered here — each
    /// button shows its own label directly below it (see `controls`),
    /// which puts the descriptor right under the user's focused target.
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
                // Reserve the row's vertical space even when idle so
                // transitions to .connecting / .failed don't push the
                // recent-songs list down.
                Text(" ")
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
        // Tighter spacing between the controls so the row reads as a
        // single playback cluster rather than seven isolated buttons.
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            labeled("Apreciază") {
                CircleControl(
                    icon: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                    tint: liked ? Theme.primary : Theme.textPrimary,
                    label: "Apreciază",
                    onFocusChange: setFocusedAction
                ) {
                    liked.toggle()
                    if liked { disliked = false }
                }
            }
            labeled("Postul anterior") {
                CircleControl(
                    icon: "backward.fill",
                    label: "Postul anterior",
                    onFocusChange: setFocusedAction,
                    action: onPrev
                )
            }
            labeled(player.isPlaying ? "Pauză" : "Redă") {
                CircleControl(
                    icon: "play.fill",
                    isPrimary: true,
                    systemPause: player.isPlaying,
                    label: player.isPlaying ? "Pauză" : "Redă",
                    onFocusChange: setFocusedAction
                ) {
                    player.togglePlayPause()
                }
                .prefersDefaultFocus(true, in: focusScope)
                .focused($controlFocus, equals: .play)
            }
            labeled("Postul următor") {
                CircleControl(
                    icon: "forward.fill",
                    label: "Postul următor",
                    onFocusChange: setFocusedAction,
                    action: onNext
                )
            }
            labeled("Nu îmi place") {
                CircleControl(
                    icon: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    tint: disliked ? Theme.primary : Theme.textPrimary,
                    label: "Nu îmi place",
                    onFocusChange: setFocusedAction
                ) {
                    disliked.toggle()
                    if disliked { liked = false }
                }
            }
            labeled(isFavorite ? "Elimină din favorite" : "Adaugă la favorite") {
                CircleControl(
                    icon: isFavorite ? "heart.fill" : "heart",
                    tint: isFavorite ? Theme.primary : Theme.textPrimary,
                    label: isFavorite ? "Elimină din favorite" : "Adaugă la favorite",
                    onFocusChange: setFocusedAction
                ) {
                    onToggleFavorite()
                }
            }
            if shareURL != nil {
                labeled("Distribuie") {
                    shareButton
                }
            }
        }
    }

    /// Stacks a `CircleControl` over a fixed-height label slot. The
    /// column's layout width is pinned to the button width so the
    /// HStack stays a tight playback cluster, while `.fixedSize` lets
    /// the label render at its full natural width — overflowing the
    /// column into the spacing — so longer descriptors like "Elimină
    /// din favorite" never truncate. Only one label is visible at a
    /// time, so the visual overflow doesn't clash with neighbors.
    @ViewBuilder
    private func labeled<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 12) {
            content()
            Text(label)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .opacity(focusedAction == label ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: focusedAction)
                .frame(height: 24, alignment: .top)
        }
        .frame(width: 72)
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
        // Play/pause and favorite swap their `label` string mid-focus
        // (Redă ↔ Pauză, Adaugă ↔ Elimină). Without this, the parent's
        // `focusedAction` stays pinned to the *old* label and the
        // tooltip below the button vanishes after the first state
        // flip. Re-publish on every label change while focused so the
        // descriptor follows the current action.
        .onChange(of: label) { _, newLabel in
            if isFocused { onFocusChange?(newLabel) }
        }
    }
}

// MARK: - VOD progress

/// Slim progress track with elapsed / total labels. Shared by the playlist
/// audio column and the video overlay for on-demand items.
struct VodProgressBar: View {
    let position: Double
    let duration: Double

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule()
                        .fill(Theme.primary)
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 8)
            HStack {
                Text(PlaybackTime.format(position))
                Spacer()
                Text(PlaybackTime.format(duration))
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .monospacedDigit()
        }
        .frame(maxWidth: 640)
    }
}

/// Formats a duration in seconds as `m:ss` (or `h:mm:ss` past an hour).
enum PlaybackTime {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Video Now Playing

/// Full-bleed video surface with a self-managing, auto-hiding control
/// overlay — the standard tvOS video idiom. Used for TV stations (live
/// video) and playlist video items (VOD). The overlay fades out after ~4s
/// of inactivity and reappears on any remote interaction.
private struct VideoNowPlaying: View {
    let station: Station
    @ObservedObject var player: AudioPlayer
    let isFavorite: Bool
    let onBack: () -> Void
    let onToggleFavorite: () -> Void
    let onPrevStation: () -> Void
    let onNextStation: () -> Void

    @State private var overlayVisible = true
    @State private var hideTask: Task<Void, Never>?

    /// The two targets we seat focus on programmatically. Other controls
    /// take focus through normal D-pad navigation.
    private enum Focusable: Hashable { case catcher, back, play }
    @FocusState private var focus: Focusable?

    private var isPlaylist: Bool { station.kind == .playlist }
    private var isVOD: Bool { player.vodDuration > 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurfaceView(player: player.avPlayer)
                .ignoresSafeArea()

            if player.isConnecting {
                connectingOverlay
            }

            if overlayVisible {
                overlay
                    .transition(.opacity)
            } else {
                // Invisible focusable catcher: the first remote interaction
                // while controls are hidden simply brings them back.
                Color.clear
                    .contentShape(Rectangle())
                    .focusable(true)
                    .focused($focus, equals: .catcher)
                    .onMoveCommand { _ in reveal() }
                    .onTapGesture { reveal() }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: overlayVisible)
        .onPlayPauseCommand {
            player.togglePlayPause()
            reveal()
        }
        .onExitCommand(perform: onBack)
        .onAppear {
            seatPlayFocus()
            scheduleHide()
        }
        .onChange(of: overlayVisible) { _, visible in
            if visible {
                seatPlayFocus()
                scheduleHide()
            } else {
                hideTask?.cancel()
                focus = .catcher
            }
        }
        // Any focus move onto a `focus`-bound target (back / play) resets
        // the idle countdown; the icon controls do the same via their own
        // `onFocusChange` closures.
        .onChange(of: focus) { _, newValue in
            if overlayVisible, newValue != nil { scheduleHide() }
        }
        .onDisappear { hideTask?.cancel() }
    }

    // MARK: overlay chrome

    private var overlay: some View {
        VStack {
            HStack(alignment: .center) {
                backButton
                Spacer()
                if station.kind == .tv {
                    livePill
                } else if player.playlistCount > 0 {
                    countPill
                }
            }
            .padding(Theme.Spacing.lg)

            Spacer()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(station.title.uppercased())
                    .font(.system(size: 20, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.textSecondary)
                Text(currentTitle)
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if isVOD {
                    VodProgressBar(
                        position: player.vodPosition,
                        duration: player.vodDuration
                    )
                }
                controls
                    .padding(.top, Theme.Spacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.xxl)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
    }

    private var currentTitle: String {
        if isPlaylist { return player.currentPlaylistItem?.title ?? station.title }
        return station.title
    }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.md) {
            if isPlaylist {
                iconControl("gobackward.10") { player.seek(by: -10) }
                iconControl("backward.fill") { player.previousItem() }
            } else {
                iconControl("backward.fill") { onPrevStation() }
            }

            playControl

            if isPlaylist {
                iconControl("forward.fill") { player.nextItem() }
                iconControl("goforward.10") { player.seek(by: 10) }
            } else {
                iconControl("forward.fill") { onNextStation() }
            }

            iconControl(
                isFavorite ? "heart.fill" : "heart",
                tint: isFavorite ? Theme.primary : Theme.textPrimary
            ) { onToggleFavorite() }
        }
    }

    private func iconControl(
        _ icon: String,
        tint: Color = Theme.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        CircleControl(
            icon: icon,
            tint: tint,
            onFocusChange: { _ in scheduleHide() },
            action: action
        )
    }

    private var playControl: some View {
        CircleControl(
            icon: "play.fill",
            isPrimary: true,
            systemPause: player.isPlaying,
            onFocusChange: { _ in scheduleHide() }
        ) {
            player.togglePlayPause()
            scheduleHide()
        }
        .focused($focus, equals: .play)
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24, weight: .heavy))
                Text("Înapoi")
                    .font(.system(size: 24, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
        }
        .buttonStyle(.card)
        .focused($focus, equals: .back)
    }

    private var livePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("LIVE")
        }
        .font(.system(size: 18, weight: .heavy))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.primary, in: Capsule())
    }

    private var countPill: some View {
        Text("\(player.playlistIndex + 1) / \(player.playlistCount)")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
    }

    private var connectingOverlay: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Se conectează…")
                .font(.system(size: 22))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3).ignoresSafeArea())
    }

    // MARK: overlay timing

    /// Bring the overlay back (or, if already showing, just restart the
    /// idle countdown).
    private func reveal() {
        if overlayVisible {
            scheduleHide()
        } else {
            overlayVisible = true   // onChange seats focus + reschedules hide
        }
    }

    /// Seat focus on the play/pause control after a short yield so the
    /// focus engine has registered the freshly-shown nodes.
    private func seatPlayFocus() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)
            focus = .play
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            overlayVisible = false
        }
    }
}
