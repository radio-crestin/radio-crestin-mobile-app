import Combine
import MediaPlayer
import UIKit

/// A command the system sends to the Now Playing app — from the Siri
/// Remote while the app is in the background, Control Center, Siri or
/// another device controlling the Apple TV.
enum RemoteCommand {
    case togglePlayPause
    case play
    case pause
    case nextStation
    case previousStation
}

/// Acts on remote commands. Implemented by `PlaybackCoordinator`, which
/// owns the policy (see its `handle(_:)`).
@MainActor
protocol RemoteCommandHandling: AnyObject {
    func handle(_ command: RemoteCommand) -> MPRemoteCommandHandlerStatus
}

/// What the system's Now Playing shows for the playing station.
struct NowPlayingSnapshot: Equatable {
    let title: String
    let artist: String?
    let album: String?
    /// Song art first, then the station logo: the first that loads shows.
    /// Asked of the CDN at `artworkPixels`.
    let artworkURLs: [URL]
    let isLiveStream: Bool
    /// The listener wants audio: playing, or connecting to a station (a
    /// stall or a pending retry included). The system then offers Pause,
    /// which cancels the connection, as the on-screen button does; with
    /// rate 0 it would offer Play, which has nothing to start.
    let isPlaying: Bool

    /// The artwork's width in pixels: the system keeps it as a 768 × 768
    /// picture (mediaremoted logs the size), to which it enlarged the
    /// API's 250 px thumbnails.
    static let artworkPixels: CGFloat = 768

    /// Nil when there is nothing to show: no station, or playback stopped.
    ///
    /// A radio song shows as title / artist with the station as album.
    /// Without a song (TV, playlists, a station with no metadata) the
    /// station name is the title and nothing repeats it below.
    init?(station: Station?, state: AudioPlayer.PlaybackState) {
        guard let station else { return nil }
        switch state {
        case .idle:
            return nil
        case .connecting, .playing:
            isPlaying = true
        case .paused, .failed:
            isPlaying = false
        }
        let song = station.kind == .radio ? station.songTitle : ""
        if song.isEmpty {
            title = station.title
            artist = nil
            album = nil
        } else {
            title = song
            artist = station.songArtist.isEmpty ? nil : station.songArtist
            album = station.title
        }
        artworkURLs = station.displayThumbnailURLs.map {
            ArtworkURL.sized($0, pixels: Self.artworkPixels)
        }
        // Radio and TV are live broadcasts; playlist items are on demand.
        isLiveStream = station.kind != .playlist
    }
}

/// Shows the playing station in the system's Now Playing and answers the
/// remote commands sent to it.
///
/// The audio keeps playing in the background (`AVAudioSession`
/// `.playback`), but without this tvOS did not know what was playing:
/// Control Center showed nothing and the Siri Remote could not pause the
/// app from the Home screen.
///
/// Seeking, skip intervals, rate, repeat / shuffle and feedback commands
/// are turned off: the streams are live radio.
@MainActor
final class NowPlayingCenter {
    private weak var handler: RemoteCommandHandling?
    private var subscription: AnyCancellable?

    /// The snapshot on screen; artwork that finishes loading is attached
    /// only if it still belongs to it.
    private var shown: NowPlayingSnapshot?

    /// The artwork candidates last asked for. A snapshot that changes
    /// only its title or playback rate keeps them, and is not reloaded
    /// (nor retried after a failure).
    private var artworkRequest: [URL] = []
    private var artworkTask: Task<Void, Never>?

    /// The artwork for `artworkRequest`, loaded through `ArtworkLoader`.
    /// Kept here while the request stands: the loader's memory may let
    /// the picture go, and the info for a pause would then lose it.
    private var artwork: MPMediaItemArtwork?

    private var playbackCommands: [MPRemoteCommand] {
        let center = MPRemoteCommandCenter.shared()
        return [
            center.togglePlayPauseCommand,
            center.playCommand,
            center.pauseCommand,
            center.stopCommand,
            center.nextTrackCommand,
            center.previousTrackCommand,
        ]
    }

    /// Registers the commands and follows the playing station and the
    /// player's state. Later calls do nothing.
    func start(
        appState: AppState,
        player: AudioPlayer,
        handler: RemoteCommandHandling
    ) {
        guard subscription == nil else { return }
        self.handler = handler
        registerCommands()
        subscription = appState.$currentStation
            .combineLatest(player.$state)
            .map { NowPlayingSnapshot(station: $0, state: $1) }
            .removeDuplicates()
            .sink { [weak self] snapshot in self?.show(snapshot) }
    }

    // MARK: - Now Playing info

    private func show(_ snapshot: NowPlayingSnapshot?) {
        shown = snapshot
        for command in playbackCommands {
            command.isEnabled = snapshot != nil
        }
        loadArtwork(from: snapshot?.artworkURLs ?? [])
        MPNowPlayingInfoCenter.default().nowPlayingInfo =
            snapshot.map(info(for:))
    }

    private func info(for snapshot: NowPlayingSnapshot) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPNowPlayingInfoPropertyIsLiveStream: snapshot.isLiveStream,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? 1.0 : 0.0,
        ]
        if let artist = snapshot.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = snapshot.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        return info
    }

    /// Follows the artwork candidates of the snapshot being shown.
    private func loadArtwork(from urls: [URL]) {
        guard urls != artworkRequest else { return }
        artworkRequest = urls
        artworkTask?.cancel()
        artworkTask = nil
        // The song art when it is in memory, otherwise the logo while the
        // song art loads.
        let inMemory = ArtworkLoader.shared.anyCachedImage(for: urls)
        artwork = inMemory.map(Self.artwork(for:))
        guard let preferred = urls.first,
              ArtworkLoader.shared.anyCachedImage(for: [preferred]) == nil
        else { return }
        artworkTask = Task { [weak self] in
            let image = await ArtworkLoader.shared.image(for: urls)
            guard !Task.isCancelled, let image, image !== inMemory,
                  let self
            else { return }
            artwork = Self.artwork(for: image)
            refreshShownInfo(for: urls)
        }
    }

    /// Re-publishes the info with the artwork that just loaded, unless
    /// the station or song moved on meanwhile.
    private func refreshShownInfo(for urls: [URL]) {
        guard let shown, shown.artworkURLs == urls else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info(for: shown)
    }

    /// Built outside the main actor: MediaPlayer may ask the artwork for
    /// its image on any queue.
    nonisolated private static func artwork(for image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: - Remote commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        let routes: [(MPRemoteCommand, RemoteCommand)] = [
            (center.togglePlayPauseCommand, .togglePlayPause),
            (center.playCommand, .play),
            (center.pauseCommand, .pause),
            // Stopping live radio is pausing it: pause already drops the
            // stream, and play tunes in again at the live edge.
            (center.stopCommand, .pause),
            (center.nextTrackCommand, .nextStation),
            (center.previousTrackCommand, .previousStation),
        ]
        for (command, action) in routes {
            Self.addTarget(to: command) { [weak self] in
                self?.handler?.handle(action) ?? .noActionableNowPlayingItem
            }
            command.isEnabled = false
        }
        let unsupported: [MPRemoteCommand] = [
            center.seekForwardCommand,
            center.seekBackwardCommand,
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.changePlaybackPositionCommand,
            center.changePlaybackRateCommand,
            center.changeRepeatModeCommand,
            center.changeShuffleModeCommand,
            center.ratingCommand,
            center.likeCommand,
            center.dislikeCommand,
            center.bookmarkCommand,
        ]
        for command in unsupported {
            command.isEnabled = false
        }
    }

    /// MediaPlayer calls command handlers on the main thread; should it
    /// ever not, the action still runs on the main actor and the command
    /// is reported handled.
    nonisolated private static func addTarget(
        to command: MPRemoteCommand,
        _ action: @escaping @MainActor () -> MPRemoteCommandHandlerStatus
    ) {
        command.addTarget { _ in
            guard Thread.isMainThread else {
                Task { @MainActor in _ = action() }
                return .success
            }
            return MainActor.assumeIsolated(action)
        }
    }
}
