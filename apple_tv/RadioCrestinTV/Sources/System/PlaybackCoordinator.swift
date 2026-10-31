import Combine
import MediaPlayer
import UIKit

/// Connects the station the listener picked (`AppState.currentStation`)
/// to the audio engine, the metadata sync, and the system's Now Playing
/// and remote commands.
///
/// It lives outside the view tree on purpose: previous / next from the
/// remote or Control Center also arrive while the app is in the
/// background, when SwiftUI may not run view updates such as `onChange`,
/// and the station change must still start playback.
///
/// It owns the audio engine so the root view can hand it to Now Playing
/// without observing it: the engine publishes twice a second during
/// on-demand playback, and a root that observed it re-ran the station
/// grids under the Now Playing cover each time.
///
/// ## Siri Remote Play/Pause
///
/// While the app is frontmost, the press is a `UIPress` that travels the
/// responder chain of the focused view: SwiftUI's `onPlayPauseCommand`
/// on the tabs and on Now Playing handles it there. tvOS turns a press
/// into a remote command (`togglePlayPauseCommand`) for the Now Playing
/// app when the app is in the background — and may forward a frontmost
/// press the app left unhandled. To make one press toggle exactly once,
/// a `togglePlayPause` remote command is ignored while the app is
/// active; the explicit play / pause commands (Control Center, Siri,
/// another device) are idempotent and always honoured.
@MainActor
final class PlaybackCoordinator: ObservableObject {
    /// The app's one audio engine.
    let player = AudioPlayer()

    private weak var appState: AppState?
    private let nowPlaying = NowPlayingCenter()
    private var stationChange: AnyCancellable?
    private var stationUpdate: AnyCancellable?
    private var seekModeChange: AnyCancellable?
    private var tuneInRefresh: Task<Void, Never>?

    /// Delay of the extra metadata poll after tuning in. The refresh run
    /// on selection is at wall clock (the live song). About 5 s in, HLS
    /// has buffered its first 6 s segment and AVPlayer exposes
    /// `currentDate()` from EXT-X-PROGRAM-DATE-TIME, so this poll fetches
    /// the song the listener actually hears instead of leaving the live
    /// one up until the next DATERANGE or the 60 s tick.
    private static let tuneInRefreshDelay: UInt64 = 5 * 1_000_000_000

    /// Wires everything once; later calls do nothing.
    func start(appState: AppState) {
        guard self.appState == nil else { return }
        self.appState = appState
        connectMetadataSync(appState: appState, player: player)
        // Restart playback only when the *station* changes, not when its
        // metadata does: every metadata merge re-publishes the station,
        // and re-setting the AVPlayer item each time cut the audio.
        stationChange = appState.$currentStation
            .compactMap { $0 }
            .removeDuplicates { $0.id == $1.id }
            .sink { [weak self] station in self?.tuneIn(to: station) }
        // New stream URLs for the same station reach the engine for its
        // next retry round.
        stationUpdate = appState.$currentStation
            .compactMap { $0 }
            .removeDuplicates {
                $0.id == $1.id && $0.stationStreams == $1.stationStreams
            }
            .sink { [weak self] station in
                self?.player.stationDidUpdate(station)
            }
        // The first value only sets the engine's mode: nothing plays yet.
        // A change re-tunes the station, so the song is fetched again for
        // the audio's new position.
        seekModeChange = appState.$seekMode
            .removeDuplicates()
            .sink { [weak self, weak appState] mode in
                guard let self else { return }
                let wasPlaying = self.player.wantsToPlay
                self.player.setSeekMode(mode)
                guard wasPlaying, let appState else { return }
                self.refreshAfterTuneIn(appState)
            }
        nowPlaying.start(appState: appState, player: player, handler: self)
    }

    /// The Siri Remote Play/Pause press handled in the app (station grids
    /// and the audio Now Playing screen): toggles the current station.
    func togglePlayback() {
        guard let station = appState?.currentStation else { return }
        if case .idle = player.state {
            player.play(station)
        } else {
            player.togglePlayPause()
        }
    }

    /// Moves to the station `step` places away in the grid the current
    /// one was opened from. Returns false when there is none.
    @discardableResult
    func skip(by step: Int) -> Bool {
        guard let appState, let current = appState.currentStation else {
            return false
        }
        let target = step > 0
            ? appState.nextStation(after: current)
            : appState.previousStation(before: current)
        guard let target else { return false }
        appState.selectStation(target)
        return true
    }

    // MARK: - Private

    private func connectMetadataSync(appState: AppState, player: AudioPlayer) {
        // Wired before the first fetch so an HLS stream already playing
        // gets the right `?timestamp=` immediately.
        appState.hlsPlaybackTimestampProvider = { [weak player] in
            player?.hlsPlaybackTimestamp
        }
        appState.hlsPlaybackDateProvider = { [weak player] in
            player?.hlsPlaybackDate
        }
        appState.isPlayingHlsProvider = { [weak player] in
            player?.isPlayingHls ?? false
        }
        // Additive over the periodic poll: when the audio reaches a song
        // change the HLS playlist announced, fetch the new song at once.
        player.onAudioReachedSongChange = { [weak appState] in
            Task { @MainActor in
                await appState?.refreshMetadataNow()
            }
        }
    }

    private func tuneIn(to station: Station) {
        player.play(station)
        guard let appState else { return }
        refreshAfterTuneIn(appState)
    }

    /// The extra metadata poll once the new audio has started.
    private func refreshAfterTuneIn(_ appState: AppState) {
        tuneInRefresh?.cancel()
        tuneInRefresh = Task { [weak appState] in
            try? await Task.sleep(nanoseconds: Self.tuneInRefreshDelay)
            guard !Task.isCancelled else { return }
            await appState?.refreshMetadataNow()
        }
    }

    /// Plays the current station unless it is already playing or tuning
    /// in. Live radio resumes at the live edge.
    private func resume(_ station: Station, on player: AudioPlayer) {
        switch player.state {
        case .paused, .failed:
            player.togglePlayPause()
        case .idle:
            player.play(station)
        default:
            break
        }
    }

    private var isFrontmost: Bool {
        UIApplication.shared.applicationState == .active
    }
}

extension PlaybackCoordinator: RemoteCommandHandling {
    func handle(_ command: RemoteCommand) -> MPRemoteCommandHandlerStatus {
        guard let station = appState?.currentStation else {
            return .noActionableNowPlayingItem
        }
        switch command {
        case .togglePlayPause:
            // Frontmost, this is the same press `onPlayPauseCommand`
            // already handled (see the type's documentation).
            guard !isFrontmost else { return .success }
            togglePlayback()
        case .play:
            resume(station, on: player)
        case .pause:
            // Connecting counts: pausing cancels a connection or a pending
            // retry, as the on-screen button does.
            if player.wantsToPlay { player.togglePlayPause() }
        case .nextStation:
            return skip(by: 1) ? .success : .noSuchContent
        case .previousStation:
            return skip(by: -1) ? .success : .noSuchContent
        }
        return .success
    }
}
