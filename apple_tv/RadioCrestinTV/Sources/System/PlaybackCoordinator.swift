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
/// on the tabs, on Now Playing and on the sheets Settings opens handles
/// it there. tvOS turns a press into a remote command
/// (`togglePlayPauseCommand`) for the Now Playing app when the app is in
/// the background — and may forward a frontmost press the app left
/// unhandled. To make one press toggle exactly once, a `togglePlayPause`
/// remote command is ignored while the app is active; the explicit play /
/// pause commands (Control Center, Siri, another device) are idempotent
/// and always honoured.
@MainActor
final class PlaybackCoordinator: ObservableObject {
    /// The app's one audio engine.
    let player = AudioPlayer()

    private weak var appState: AppState?
    private let nowPlaying = NowPlayingCenter()
    private var stationChange: AnyCancellable?
    private var stationUpdate: AnyCancellable?
    private var seekModeChange: AnyCancellable?
    private var pauseChange: AnyCancellable?
    private var retryChange: AnyCancellable?

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
            .sink { [weak self] station in self?.player.play(station) }
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
        // A change re-tunes the station, and the song is fetched again for
        // the audio's new position once it plays.
        seekModeChange = appState.$seekMode
            .removeDuplicates()
            .sink { [weak self] mode in self?.player.setSeekMode(mode) }
        // The engine publishes often during on-demand playback; the grids
        // only need to know whether the current station is paused.
        pauseChange = player.$state
            .map { state in
                if case .paused = state { return true }
                return false
            }
            .removeDuplicates()
            .sink { [weak appState] paused in
                appState?.isPlaybackPaused = paused
            }
        // A tune-in that falls into a retry, or fails, before its song
        // came names the station from then on.
        retryChange = player.$isRetrying
            .combineLatest(player.$state)
            .filter { retrying, state in
                if case .failed = state { return true }
                return retrying
            }
            .sink { [weak appState] _ in appState?.endAwaitingSong() }
        nowPlaying.start(appState: appState, player: player, handler: self)
    }

    /// The Siri Remote Play/Pause press handled in the app (the tabs, the
    /// audio Now Playing screen and the sheets Settings opens): toggles
    /// the current station.
    ///
    /// After a relaunch no station is current: the press plays the one
    /// played last, as Apple Music resumes its last item, without opening
    /// Now Playing over the grid the listener is on.
    func togglePlayback() {
        guard let appState else { return }
        guard let station = appState.currentStation else {
            if let last = lastPlayedStation(in: appState) {
                appState.selectStation(last)
            }
            return
        }
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
        appState.hlsHeardDateProvider = { [weak player] in
            player?.hlsHeardDate
        }
        appState.followsHlsAudioProvider = { [weak player] in
            player?.followsHlsAudio ?? false
        }
        appState.isPlayingHlsProvider = { [weak player] in
            player?.isPlayingHls ?? false
        }
        appState.isPlayingProvider = { [weak player] in
            player?.isPlaying ?? false
        }
        appState.directStreamPausedAtProvider = { [weak player] in
            player?.directStreamPausedAt
        }
        appState.audioStoppedAtProvider = { [weak player] in
            player?.stoppedAt
        }
        // Additive over the periodic poll, which follows the live song:
        // the song the listener hears is fetched for the audio's position
        // as soon as it is known, when a live item starts playing (a
        // tune-in, a resume, a recovery, the fallback to another stream),
        // and again whenever the audio reaches a song change the HLS
        // playlist announced.
        let refresh: () -> Void = { [weak appState] in
            Task { @MainActor in
                await appState?.refreshMetadataNow()
            }
        }
        player.onLiveAudioStarted = refresh
        player.onAudioReachedSongChange = refresh
    }

    /// The station played last (`AppState.recentSlugs`), while the catalog
    /// still lists it.
    private func lastPlayedStation(in appState: AppState) -> Station? {
        guard let slug = appState.recentSlugs.first else { return nil }
        return appState.stations.first { $0.slug == slug }
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
