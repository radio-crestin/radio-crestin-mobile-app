import SwiftUI

/// Full-screen Now Playing — large artwork, station + song metadata,
/// recent song history, and a row of playback controls (play/pause,
/// like, dislike, favorite, share). Pressing menu/back returns to the
/// previous tab.
struct NowPlayingView: View {
    let station: Station
    let isFavorite: Bool
    /// Where the listener is on the station's broadcast timeline: where
    /// its song clock puts the audio (`AppState.heardClock`).
    let heardClock: HeardClock
    /// The station's song is on its way (`AppState.isAwaitingSong`).
    let isAwaitingSong: Bool
    @ObservedObject var player: AudioPlayer
    @ObservedObject var songHistory: SongHistoryStore
    /// The listener's likes and dislikes, kept per song across launches.
    @ObservedObject var songRatings: SongRatings

    let onBack: () -> Void
    let onToggleFavorite: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

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
        /// The Share button, which gets focus back when the share sheet
        /// closes: left to itself, the focus engine picked the back button
        /// in the top-left corner.
        case share
    }
    @FocusState private var controlFocus: ControlFocus?

    /// Drives the live playlist sync: poll only while this screen is
    /// visible AND the scene is active.
    @Environment(\.scenePhase) private var scenePhase

    /// Sizes the backdrop's picture as the artwork's (see
    /// `backgroundArtwork`).
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if player.playlistDepleted {
                // A live sync removed every playable item mid-session.
                unavailableLayout(
                    icon: "rectangle.on.rectangle.slash",
                    message: "Playlistul nu mai conține nimic de redat. Conținutul a fost actualizat între timp — încearcă din nou mai târziu."
                )
            } else if station.hasOnlyUnplayableItems
                        && player.currentPlaylistItem == nil {
                // Playlist whose entries (YouTube clips/playlists or
                // unknown types) can't be embedded on tvOS. Explain
                // rather than showing a broken player. (Cleared
                // automatically if a live sync brings playable items
                // and playback starts.)
                unavailableLayout(
                    icon: "play.rectangle.on.rectangle",
                    message: "Acest playlist conține doar elemente care nu pot fi redate pe TV (de exemplu clipuri YouTube). Deschide aplicația Radio Creștin pe telefon pentru a le urmări."
                )
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
            if isSharing { closeShareSheet() } else { onBack() }
        }
        // Live playlist sync lifecycle: poll every 5s while this screen
        // shows a playlist station and the scene is active; stop on
        // disappear, backgrounding, or navigating to another station.
        .onAppear { startPlaylistSyncIfNeeded() }
        .onDisappear { player.stopPlaylistSync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startPlaylistSyncIfNeeded()
            } else {
                player.stopPlaylistSync()
            }
        }
        .onChange(of: station.id) { _, _ in
            // Prev/next can swap the station under this mounted view —
            // restart (or stop) the poller to match the new kind.
            player.stopPlaylistSync()
            startPlaylistSyncIfNeeded()
        }
    }

    /// Start polling only when the visible station is a playlist and the
    /// scene is active. `startPlaylistSync` itself is double-start safe.
    private func startPlaylistSyncIfNeeded() {
        guard station.kind == .playlist, scenePhase == .active else { return }
        player.startPlaylistSync()
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
            // Full-width focus sections, here and around the top bar: the
            // focus engine only moves to what lies in the direction
            // pressed, and the back button in the corner is above none of
            // the controls, so Up never reached it. Down from it comes
            // back to play/pause, where the screen opens, rather than to
            // the leftmost control under the corner.
            .frame(maxWidth: .infinity)
            .focusSection()
            .defaultFocus($controlFocus, .play, priority: .userInitiated)
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
                .focusSection()
                Spacer()
            }
            .padding(Theme.Spacing.lg)
            // The share sheet keeps focus: Up from its button would
            // otherwise land on the back button behind it.
            .disabled(isSharing)

            if isSharing, let url = shareURL {
                ShareSheet(
                    stationTitle: station.title,
                    url: url,
                    onDismiss: closeShareSheet
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

    // MARK: - Unavailable fallback (YouTube-only / emptied playlist)

    private func unavailableLayout(
        icon: String,
        message: String
    ) -> some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: icon)
                    .font(.system(size: 90))
                    .foregroundStyle(Theme.textTertiary)
                Text(station.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
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
        .buttonStyle(OwnFocusButtonStyle())
        .focused($backButtonFocused)
    }

    /// Square artwork slot shared by both branches of `artwork`, so a
    /// playlist item's cover and a station logo occupy the same space.
    private static let artworkSide: CGFloat = 460
    private static let artworkCornerRadius: CGFloat = 28

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
                        AspectFillImage(image: image)
                    } else {
                        StationArtwork(
                            station: station,
                            cornerRadius: Self.artworkCornerRadius
                        )
                    }
                }
                .frame(width: Self.artworkSide, height: Self.artworkSide)
                .clipShape(
                    RoundedRectangle(cornerRadius: Self.artworkCornerRadius)
                )
            } else {
                StationArtwork(
                    station: station,
                    cornerRadius: Self.artworkCornerRadius,
                    targetSize: CGSize(
                        width: Self.artworkSide,
                        height: Self.artworkSide
                    )
                )
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 32, x: 0, y: 12)
    }

    /// The artwork's picture, the song cover or else the logo, blurred
    /// behind the screen as on Android TV. It asks for the artwork's own
    /// URLs, so the picture comes from memory instead of a second download
    /// and decoding at another size.
    private var backgroundArtwork: some View {
        Theme.background
            .overlay {
                ArtworkImage(
                    urls: StationArtwork.urls(
                        for: station,
                        width: Self.artworkSide,
                        scale: displayScale
                    )
                )
            }
            // Opaque because the picture is now cropped to the screen: a
            // regular blur would fade every cropped edge into the dark
            // background, ringing the backdrop with a vignette whose sides
            // depend on the logo's proportions.
            .blur(radius: 60, opaque: true)
            // 0.65 left a white logo's backdrop at #595959, where the small
            // captions measured 3.3:1; 0.78 keeps it near #383838.
            .overlay(Color.black.opacity(0.78))
            .accessibilityHidden(true)
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
            // Room for the tallest song, two title lines and an artist,
            // with the song at its top: the station line and the title's
            // first line stay where they are whatever comes next, one
            // title line or two, an artist or none, the station's name
            // until its song arrives, and the controls under the room keep
            // their place. With the song at the bottom of the room, the
            // station line and the title jumped by up to 108 pt at such
            // changes, as when a tune-in showed the station's name and its
            // song a moment later.
            ZStack(alignment: .topLeading) {
                stationAndSong(title: "\n", artist: " ", namesStation: true)
                    .hidden()
                    .accessibilityHidden(true)
                stationAndSong(
                    title: displaySongTitle,
                    artist: station.songArtist,
                    namesStation: hasSong || isAwaitingSong
                )
                // Added to the last block rather than laid over it while
                // the two cross (see `compositingGroup` below): what both
                // show, as the station line between two songs of a
                // station, stays as it is through the fade. Two layers at
                // half opacity dimmed it by a quarter halfway, a blink.
                .blendMode(.plusLighter)
                // Another song or station fades in over the last as a
                // whole and in place, as the artwork beside it does. One
                // faded out before the next faded in blinked (60 fps
                // recordings, 2026-10-31).
                .id(shownSong)
                .transition(.opacity)
            }
            // The blocks add up among themselves, then show over the
            // backdrop as usual: added to the backdrop, the grey text
            // would have turned lighter.
            .compositingGroup()
            // The app's content-change fade.
            .animation(.easeInOut(duration: 0.25), value: shownSong)

            // 32 pt under the room, which only the longest songs fill.
            controls
                .padding(.top, Theme.Spacing.sm)

            statusLine

            recentSongs
        }
        // Cap the column so giant station logos / song titles don't push
        // the controls off screen.
        .frame(maxWidth: 900, alignment: .leading)
    }

    /// The station line over the song title (two lines at most) and its
    /// artist.
    private func stationAndSong(
        title: String,
        artist: String,
        namesStation: Bool
    ) -> some View {
        // The station line close over the title, one heading: 24 pt
        // apart, the two read as separate blocks.
        VStack(alignment: .leading, spacing: 12) {
            stationLine(namesStation: namesStation)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
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
                    onFocusChange: controlFocusChanged
                ) { player.seek(by: -10) }
            }
            labeled("Anterior") {
                CircleControl(
                    icon: "backward.fill",
                    label: "Anterior",
                    onFocusChange: controlFocusChanged
                ) { player.previousItem() }
            }
            labeled(playPauseLabel) {
                CircleControl(
                    icon: "play.fill",
                    isPrimary: true,
                    systemPause: player.wantsToPlay,
                    label: playPauseLabel,
                    onFocusChange: controlFocusChanged
                ) { player.togglePlayPause() }
                .prefersDefaultFocus(true, in: focusScope)
                .focused($controlFocus, equals: .play)
            }
            labeled("Următor") {
                CircleControl(
                    icon: "forward.fill",
                    label: "Următor",
                    onFocusChange: controlFocusChanged
                ) { player.nextItem() }
            }
            labeled("Înainte 10s") {
                CircleControl(
                    icon: "goforward.10",
                    label: "Înainte 10s",
                    onFocusChange: controlFocusChanged
                ) { player.seek(by: 10) }
            }
            labeled(isFavorite ? "Elimină din favorite" : "Adaugă la favorite") {
                CircleControl(
                    icon: isFavorite ? "heart.fill" : "heart",
                    tint: isFavorite ? Theme.primary : Theme.textPrimary,
                    label: isFavorite ? "Elimină din favorite" : "Adaugă la favorite",
                    onFocusChange: controlFocusChanged
                ) { onToggleFavorite() }
            }
        }
    }

    /// The station's name, listeners and rating. Without a song the title
    /// under the line is the station's name, so the line leaves it out
    /// rather than say it twice (`namesStation`); its height stays, so the
    /// title does not move when a song arrives.
    private func stationLine(namesStation: Bool) -> some View {
        ZStack(alignment: .leading) {
            // The height of the listener count, the line's tallest text,
            // also when the line holds nothing: a station without
            // listeners or reviews shows none before its song.
            Text(" ")
                .font(.system(size: 21))
                .hidden()
                .accessibilityHidden(true)
            stationLineItems(namesStation: namesStation)
                // One line at its natural width, far narrower than the
                // column. Laid out in the song block's reserved space, the
                // line could be offered a few points less and wrap the
                // review count ("(1" over ")"). Fixed on the items, not
                // around the stack: there the items were handed the line's
                // width to share out, and Radio Gosen's "(244)" shrank to
                // "(…".
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func stationLineItems(namesStation: Bool) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            if namesStation {
                Text(station.title.uppercased())
                    .font(.system(size: 20, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let listeners = station.totalListeners, listeners > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "headphones")
                    // A new count rolls in place, as the rest of the screen
                    // eases its changes. With proportional digits 74 to 73
                    // was narrower, and the stars after it moved.
                    Text("\(listeners)")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(listeners)))
                }
                .font(.system(size: 21))
                .foregroundStyle(Theme.textSecondary)
                // One element: the icon alone read as "Audiobook".
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    RomanianCount.phrase(
                        listeners, one: "ascultător", many: "ascultători"
                    )
                )
            }
            if station.averageRating > 0 {
                RatingStars(
                    rating: station.averageRating,
                    count: station.reviewCount,
                    size: 21
                )
            }
        }
        // Over the whole line: a count that gains or loses a digit (99 to
        // 100) moves the stars, which then slide as it rolls. Eased with
        // the count only, they jumped in one frame, and 100 to 99 drew its
        // last 0 against the first star.
        .animation(.easeInOut(duration: 0.25), value: station.totalListeners)
    }

    /// Fixed-height status line that surfaces the connection spinner (or
    /// the wait before another try once every stream failed) or the
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
                Text(player.connectingMessage)
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
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 22, weight: .medium))
        .frame(height: 40, alignment: .center)
        // Leading, like the song title, the controls and the history
        // around it; centred, the spinner floated alone mid-column.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasSong: Bool { !station.songTitle.isEmpty }

    /// The song title; without a song the station's name, or nothing while
    /// the song is on its way, the station named in its line: the song
    /// then only fades in.
    private var displaySongTitle: String {
        if hasSong { return station.songTitle }
        return isAwaitingSong ? "" : station.title
    }

    /// What the song block shows, to fade from one to the next.
    private var shownSong: [String] {
        [station.slug, displaySongTitle, station.songArtist]
    }

    /// "Pauză" while the listener wants audio, connecting included, so the
    /// button can cancel a connection or a retry; "Redă" otherwise.
    private var playPauseLabel: String {
        player.wantsToPlay ? "Pauză" : "Redă"
    }

    // MARK: - Controls

    private var controls: some View {
        // The shown song's like or dislike, as saved for it.
        let rating = songRatings.rating(of: station)
        let liked = rating == .liked
        let disliked = rating == .disliked
        // Tighter spacing between the controls so the row reads as a
        // single playback cluster rather than seven isolated buttons.
        return HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            labeled("Apreciază") {
                CircleControl(
                    icon: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                    tint: liked ? Theme.primary : Theme.textPrimary,
                    isSelected: liked,
                    label: "Apreciază",
                    onFocusChange: controlFocusChanged
                ) {
                    songRatings.press(.liked, for: station)
                }
            }
            labeled("Postul anterior") {
                CircleControl(
                    icon: "backward.fill",
                    label: "Postul anterior",
                    onFocusChange: controlFocusChanged,
                    action: onPrev
                )
            }
            labeled(playPauseLabel) {
                CircleControl(
                    icon: "play.fill",
                    isPrimary: true,
                    systemPause: player.wantsToPlay,
                    label: playPauseLabel,
                    onFocusChange: controlFocusChanged
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
                    onFocusChange: controlFocusChanged,
                    action: onNext
                )
            }
            labeled("Nu îmi place") {
                CircleControl(
                    icon: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    tint: disliked ? Theme.primary : Theme.textPrimary,
                    isSelected: disliked,
                    label: "Nu îmi place",
                    onFocusChange: controlFocusChanged
                ) {
                    songRatings.press(.disliked, for: station)
                }
            }
            labeled(isFavorite ? "Elimină din favorite" : "Adaugă la favorite") {
                CircleControl(
                    icon: isFavorite ? "heart.fill" : "heart",
                    tint: isFavorite ? Theme.primary : Theme.textPrimary,
                    label: isFavorite ? "Elimină din favorite" : "Adaugă la favorite",
                    onFocusChange: controlFocusChanged
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
                // The control above carries this name for VoiceOver.
                .accessibilityHidden(true)
                .opacity(focusedAction == label ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: focusedAction)
                .frame(height: 24, alignment: .top)
        }
        .frame(width: 72)
    }

    /// Shows the label of the control that took focus, and hides it once
    /// focus leaves the row (for the back button or the share sheet)
    /// instead of leaving the last control's label up.
    private func controlFocusChanged(_ label: String, isFocused: Bool) {
        if isFocused {
            focusedAction = label
        } else {
            // The focus engine reports the loss and the next control's
            // gain together, in either order: look once both are in. Only
            // when no control took over is the label still this one.
            DispatchQueue.main.async {
                if focusedAction == label { focusedAction = nil }
            }
        }
    }

    private var shareURL: URL? {
        URL(string: "https://www.radiocrestin.ro/radio/\(station.slug)")
    }

    @ViewBuilder
    private var shareButton: some View {
        if shareURL != nil {
            CircleControl(
                icon: "square.and.arrow.up",
                label: "Distribuie",
                onFocusChange: controlFocusChanged
            ) {
                isSharing = true
            }
            .focused($controlFocus, equals: .share)
        }
    }

    private func closeShareSheet() {
        isSharing = false
        controlFocus = .share
    }

    // MARK: - Recent songs

    /// Always renders the header and three rows so the layout doesn't
    /// shift when entries arrive from the API a moment after the view
    /// mounts. Empty slots, and the header while there is nothing under
    /// it, are invisible but reserve their height.
    private var recentSongs: some View {
        // The songs before the one shown above, which the history lists
        // first once it has it.
        let entries = SongTimeline.before(
            shownTitle: station.songTitle,
            artist: station.songArtist,
            in: songHistory.entries(for: station.slug)
        )
        let hasEntries = !entries.isEmpty
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Melodii recente")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .opacity(hasEntries ? 1 : 0)
                .accessibilityHidden(!hasEntries)
            // Drawn again as the minutes pass, not only when a sync or a
            // song changes the screen: the times ran up to a minute late.
            TimelineView(.periodic(from: .now, by: Self.songAgeRefresh)) {
                context in
                // The times count back from what the listener hears, where
                // the title's clock puts the audio: in the 2 and 5 minute
                // modes a song they have just reached aired minutes ago, and
                // read "acum 2 min" against the wall clock, connecting and
                // paused included.
                let heardNow = heardClock.heardNow(at: context.date)
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(0..<3, id: \.self) { idx in
                        _SongHistoryRow(
                            entry: entries.dropFirst(idx).first,
                            heardNow: heardNow
                        )
                    }
                }
            }
        }
        // The header and the first rows appear together when the history
        // loads (or leave when the next station has none), and each row
        // fades to its new song as the title fades to the next; 250 ms is
        // the app's content-change fade, so they ease in instead of
        // popping.
        .animation(.easeInOut(duration: 0.25), value: entries.map(\.id))
    }

    /// How often "Melodii recente" works its times out again: at most this
    /// late on the minute a time turns.
    private static let songAgeRefresh: TimeInterval = 10
}

/// Single row in the "Melodii recente" list. Renders an empty (but
/// space-reserving) row when `entry` is nil so the layout is stable
/// before the API call completes.
private struct _SongHistoryRow: View {
    let entry: SongEntry?
    /// The broadcast moment the listener hears; the time counts back
    /// from it.
    let heardNow: Date

    @Environment(\.displayScale) private var displayScale

    private static let thumbnailSide: CGFloat = 48

    // The title at tvOS's smallest text style (Caption 2, 23 pt), artist
    // and time just under it in the secondary colour: at 18/16/14 pt and
    // half white they were hard to read from the couch over a light
    // station's backdrop.
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            placeholderArt
                .overlay {
                    if let url = entry?.thumbnailUrl.flatMap(URL.init(string:)) {
                        ArtworkImage(urls: [
                            ArtworkURL.sized(
                                url,
                                pixels: Self.thumbnailSide * displayScale
                            ),
                        ])
                    }
                }
                .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry?.title ?? " ")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(entry?.artist ?? " ")
                    .font(.system(size: 21))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(entry.map {
                SongAge.phrase(startedAt: $0.timestamp, heardNow: heardNow)
            } ?? " ")
                .font(.system(size: 21))
                .foregroundStyle(Theme.textSecondary)
        }
        .opacity(entry == nil ? 0 : 1)
        .frame(height: 54)
        // One element per song for VoiceOver: title, artist and time.
        .accessibilityElement(children: .combine)
        .accessibilityHidden(entry == nil)
    }

    private var placeholderArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surfaceVariant)
            Image(systemName: "music.note")
                .foregroundStyle(Theme.textTertiary)
                .font(.system(size: 20))
        }
    }
}

/// How long before the moment heard a song started, as "Melodii recente"
/// says it: "acum", "acum 5 min", then hours and days spelled out as on
/// Android TV — "acum 1 oră", "acum 3 ore", "acum 2 zile" — with "de"
/// from 20 on ("acum 20 de ore"). They read "2h" and "3z", and "z" is no
/// Romanian unit.
enum SongAge {
    static func phrase(startedAt start: Date, heardNow: Date) -> String {
        let minutes = Int(heardNow.timeIntervalSince(start)) / 60
        if minutes < 1 { return "acum" }
        if minutes < 60 { return "acum \(minutes) min" }
        let hours = minutes / 60
        if hours < 24 {
            return "acum "
                + RomanianCount.phrase(hours, one: "oră", many: "ore")
        }
        return "acum "
            + RomanianCount.phrase(hours / 24, one: "zi", many: "zile")
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
/// loss so the parent can render a tooltip-style status line below the
/// row.
private struct CircleControl: View {
    let icon: String
    var isPrimary: Bool = false
    var systemPause: Bool = false
    var tint: Color = Theme.textPrimary
    /// A toggle that is on (a liked song): VoiceOver says "selected", as
    /// the filled pink icon shows it. Its name stays what it does.
    var isSelected: Bool = false
    /// What the control does, in Romanian: its tooltip and its VoiceOver
    /// name.
    var label: String = ""
    var onFocusChange: ((_ label: String, _ isFocused: Bool) -> Void)? = nil
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
        // A button named like its tooltip for VoiceOver. Not being a
        // `Button`, it read the symbol inside as an English image
        // ("Back", "Pause", "Love").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(label, focused)
        }
        // Play/pause and favorite swap their `label` string mid-focus
        // (Redă ↔ Pauză, Adaugă ↔ Elimină). Without this, the parent's
        // `focusedAction` stays pinned to the *old* label and the
        // tooltip below the button vanishes after the first state
        // flip. Re-publish on every label change while focused so the
        // descriptor follows the current action.
        .onChange(of: label) { _, newLabel in
            if isFocused { onFocusChange?(newLabel, true) }
        }
    }
}

/// A button that is drawn only by its label, for a label that draws its
/// own focus (the back button's pink capsule). `.plain` added tvOS's focus
/// platter, a light rounded rectangle, around that capsule: a second,
/// mismatched focus ring.
private struct OwnFocusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Connection status

private extension AudioPlayer {
    /// What a `.connecting` state tells the listener. After every stream
    /// failed, the engine waits before the next round (`isRetrying`):
    /// saying so explains why the spinner lasts longer than a connection.
    var connectingMessage: String {
        isRetrying ? "Se reîncearcă…" : "Se conectează…"
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

    // Labels as in the audio layout, for VoiceOver: the overlay shows no
    // tooltips.
    private var controls: some View {
        HStack(spacing: Theme.Spacing.md) {
            if isPlaylist {
                iconControl("gobackward.10", label: "Înapoi 10s") {
                    player.seek(by: -10)
                }
                iconControl("backward.fill", label: "Anterior") {
                    player.previousItem()
                }
            } else {
                iconControl("backward.fill", label: "Postul anterior") {
                    onPrevStation()
                }
            }

            playControl

            if isPlaylist {
                iconControl("forward.fill", label: "Următor") {
                    player.nextItem()
                }
                iconControl("goforward.10", label: "Înainte 10s") {
                    player.seek(by: 10)
                }
            } else {
                iconControl("forward.fill", label: "Postul următor") {
                    onNextStation()
                }
            }

            iconControl(
                isFavorite ? "heart.fill" : "heart",
                label: isFavorite ? "Elimină din favorite" : "Adaugă la favorite",
                tint: isFavorite ? Theme.primary : Theme.textPrimary
            ) { onToggleFavorite() }
        }
    }

    private func iconControl(
        _ icon: String,
        label: String,
        tint: Color = Theme.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        CircleControl(
            icon: icon,
            tint: tint,
            label: label,
            onFocusChange: { _, _ in scheduleHide() },
            action: action
        )
    }

    private var playControl: some View {
        CircleControl(
            icon: "play.fill",
            isPrimary: true,
            systemPause: player.wantsToPlay,
            label: player.wantsToPlay ? "Pauză" : "Redă",
            onFocusChange: { _, _ in scheduleHide() }
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
            Text(player.connectingMessage)
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
