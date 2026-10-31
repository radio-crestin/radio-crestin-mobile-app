import AVFoundation
import XCTest
@testable import RadioCrestinTV

/// The engine around a play request: the state the listener sees and the
/// item the engine holds. The synchronous tests end before the run loop
/// turns, so AVPlayer never loads anything. The asynchronous ones point the
/// streams at a `SilentServer`, so AVPlayer keeps connecting and only the
/// events a test sends move the engine.
@MainActor
final class AudioPlayerTests: XCTestCase {

    /// Port 9 (discard) on the loopback: nothing answers there, and no
    /// result of AVPlayer's attempt reaches the engine before a test ends.
    private let liveStream = StationStream(
        order: 0, type: "HLS",
        streamUrl: "http://127.0.0.1:9/hls/test/index.m3u8"
    )

    /// An engine that reports failures nowhere: the test host app is set
    /// up with the production analytics project.
    private func makePlayer() -> AudioPlayer {
        AudioPlayer(reportError: { _, _, _ in })
    }

    private func station(streams: [StationStream]) -> Station {
        Station(
            id: 1,
            slug: "test",
            title: "Test",
            order: 0,
            thumbnailUrl: nil,
            totalListeners: nil,
            stationStreams: streams,
            uptime: nil,
            nowPlaying: nil,
            reviewsStats: nil,
            stationType: nil,
            playlistItems: nil,
            hlsDvrStreamUrl: nil
        )
    }

    func test_a_new_player_is_idle_and_wants_nothing() {
        let player = makePlayer()
        XCTAssertEqual(player.state, .idle)
        XCTAssertFalse(player.wantsToPlay)
        XCTAssertFalse(player.isRetrying)
    }

    func test_play_connects_and_wants_to_play() {
        let player = makePlayer()

        player.play(station(streams: [liveStream]))

        XCTAssertEqual(player.state, .connecting("Test"))
        XCTAssertTrue(player.wantsToPlay)
        XCTAssertFalse(player.isRetrying)
        XCTAssertNotNil(player.avPlayer.currentItem)
        XCTAssertTrue(player.isPlayingHls)
    }

    func test_a_station_without_a_usable_stream_url_fails_for_good() {
        let player = makePlayer()
        let broken = StationStream(order: 0, type: "MP3", streamUrl: "")

        player.play(station(streams: [broken]))

        guard case .failed = player.state else {
            return XCTFail("expected .failed, got \(player.state)")
        }
        XCTAssertFalse(player.wantsToPlay)
        XCTAssertFalse(player.isRetrying)
        XCTAssertNil(player.avPlayer.currentItem)
    }

    func test_pausing_while_connecting_stops_the_attempt() {
        let player = makePlayer()
        player.play(station(streams: [liveStream]))

        player.togglePlayPause()

        XCTAssertEqual(player.state, .paused("Test"))
        XCTAssertFalse(player.wantsToPlay)
        XCTAssertFalse(player.isRetrying)
        XCTAssertNil(player.avPlayer.currentItem)
        XCTAssertFalse(player.isPlayingHls)
    }

    func test_resuming_a_paused_live_station_tunes_in_again() {
        let player = makePlayer()
        player.play(station(streams: [liveStream]))
        player.togglePlayPause()

        player.togglePlayPause()

        XCTAssertEqual(player.state, .connecting("Test"))
        XCTAssertNotNil(player.avPlayer.currentItem)
    }

    func test_toggle_while_idle_does_nothing() {
        let player = makePlayer()

        player.togglePlayPause()

        XCTAssertEqual(player.state, .idle)
        XCTAssertNil(player.avPlayer.currentItem)
    }

    func test_stop_returns_to_idle_and_drops_the_item() {
        let player = makePlayer()
        player.play(station(streams: [liveStream]))

        player.stop()

        XCTAssertEqual(player.state, .idle)
        XCTAssertFalse(player.wantsToPlay)
        XCTAssertNil(player.avPlayer.currentItem)
    }

    // MARK: - Live item events (the supervisor's decisions carried out)

    private func path(of item: AVPlayerItem?) -> String? {
        (item?.asset as? AVURLAsset)?.url.path
    }

    private func postFailedToPlayToEnd(_ item: AVPlayerItem?) {
        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            userInfo: [
                AVPlayerItemFailedToPlayToEndTimeErrorKey:
                    URLError(.resourceUnavailable),
            ]
        )
    }

    /// An HLS station with its MP3 fallback, both on `server`.
    private func hlsWithFallback(on server: SilentServer) -> Station {
        station(streams: [
            server.stream("HLS", at: "/hls/index.m3u8", order: 0),
            server.stream("MP3", at: "/live.mp3", order: 1),
        ])
    }

    /// E2a: the HLS origin goes away mid-play; AVPlayer's only signal is
    /// `AVPlayerItemFailedToPlayToEndTime`, and the MP3 must follow.
    func test_an_hls_item_that_breaks_off_falls_back_to_the_next_stream() async throws {
        let server = try SilentServer()
        let player = makePlayer()
        player.play(hlsWithFallback(on: server))
        let hls = try XCTUnwrap(player.avPlayer.currentItem)
        XCTAssertEqual(path(of: hls), "/hls/index.m3u8")

        postFailedToPlayToEnd(hls)

        let movedOn = await eventually { player.avPlayer.currentItem != hls }
        XCTAssertTrue(movedOn)
        XCTAssertEqual(path(of: player.avPlayer.currentItem), "/live.mp3")
        XCTAssertEqual(player.state, .connecting("Test"))
        XCTAssertFalse(player.isPlayingHls)
    }

    func test_a_live_item_that_plays_to_its_end_moves_on() async throws {
        let server = try SilentServer()
        let player = makePlayer()
        player.play(hlsWithFallback(on: server))
        let hls = try XCTUnwrap(player.avPlayer.currentItem)

        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime, object: hls
        )

        let movedOn = await eventually { player.avPlayer.currentItem != hls }
        XCTAssertTrue(movedOn)
        XCTAssertEqual(path(of: player.avPlayer.currentItem), "/live.mp3")
    }

    func test_when_every_stream_failed_it_waits_and_says_it_is_retrying() async throws {
        let server = try SilentServer()
        let player = makePlayer()
        player.play(hlsWithFallback(on: server))
        let hls = try XCTUnwrap(player.avPlayer.currentItem)
        postFailedToPlayToEnd(hls)
        let onMp3 = await eventually { player.avPlayer.currentItem != hls }
        XCTAssertTrue(onMp3)

        postFailedToPlayToEnd(player.avPlayer.currentItem)

        let waiting = await eventually { player.avPlayer.currentItem == nil }
        XCTAssertTrue(waiting)
        XCTAssertTrue(player.isRetrying)
        XCTAssertEqual(player.state, .connecting("Test"))
        XCTAssertTrue(player.wantsToPlay)
    }

    func test_events_of_a_replaced_item_are_ignored() async throws {
        let server = try SilentServer()
        let player = makePlayer()
        player.play(hlsWithFallback(on: server))
        let hls = try XCTUnwrap(player.avPlayer.currentItem)
        postFailedToPlayToEnd(hls)
        let onMp3 = await eventually { player.avPlayer.currentItem != hls }
        XCTAssertTrue(onMp3)
        let mp3 = player.avPlayer.currentItem

        postFailedToPlayToEnd(hls)
        await letQueuedWorkRun()

        XCTAssertEqual(player.avPlayer.currentItem, mp3)
        XCTAssertFalse(player.isRetrying)
    }

    // MARK: - New stream URLs (catalog refresh during retries)

    func test_new_stream_urls_wait_for_the_next_round() throws {
        let server = try SilentServer()
        let player = makePlayer()
        player.play(station(streams: [server.stream("HLS", at: "/old.m3u8")]))
        let item = player.avPlayer.currentItem

        player.stationDidUpdate(
            station(streams: [server.stream("HLS", at: "/new.m3u8")])
        )

        // The attempt in progress is not cut for them.
        XCTAssertEqual(player.avPlayer.currentItem, item)
        XCTAssertEqual(path(of: item), "/old.m3u8")
    }

    /// Retries go on until the listener gives up; they must use the URLs
    /// the catalog lists now, not the ones of the original play request.
    func test_a_retry_round_uses_the_stream_urls_the_catalog_lists_now() async throws {
        let server = try SilentServer()
        let player = makePlayer()
        player.play(station(streams: [server.stream("HLS", at: "/old.m3u8")]))
        postFailedToPlayToEnd(player.avPlayer.currentItem)
        let waiting = await eventually { player.isRetrying }
        XCTAssertTrue(waiting)

        player.stationDidUpdate(
            station(streams: [server.stream("HLS", at: "/new.m3u8")])
        )

        // The first wait is 2 s, ended by the once-a-second look.
        let retried = await eventually(timeout: 6) {
            player.avPlayer.currentItem != nil
        }
        XCTAssertTrue(retried)
        XCTAssertEqual(path(of: player.avPlayer.currentItem), "/new.m3u8")
    }

    // MARK: - System pauses

    func test_an_interruption_pauses_and_its_end_tunes_in_again() {
        let player = makePlayer()
        player.play(station(streams: [liveStream]))

        player.handleSystemEvent(.interruptionBegan)

        XCTAssertEqual(player.state, .paused("Test"))
        XCTAssertNil(player.avPlayer.currentItem)

        player.handleSystemEvent(.interruptionEnded(shouldResume: true))

        XCTAssertEqual(player.state, .connecting("Test"))
        XCTAssertNotNil(player.avPlayer.currentItem)
    }

    func test_an_interruption_that_ends_without_the_resume_hint_stays_paused() {
        let player = makePlayer()
        player.play(station(streams: [liveStream]))

        player.handleSystemEvent(.interruptionBegan)
        player.handleSystemEvent(.interruptionEnded(shouldResume: false))

        XCTAssertEqual(player.state, .paused("Test"))
        XCTAssertNil(player.avPlayer.currentItem)
    }

    func test_a_station_the_listener_paused_does_not_resume_after_an_interruption() {
        let player = makePlayer()
        player.play(station(streams: [liveStream]))
        player.togglePlayPause()

        player.handleSystemEvent(.interruptionBegan)
        player.handleSystemEvent(.interruptionEnded(shouldResume: true))

        XCTAssertEqual(player.state, .paused("Test"))
        XCTAssertNil(player.avPlayer.currentItem)
    }

    func test_a_lost_output_pauses_for_good() {
        let player = makePlayer()
        player.play(station(streams: [liveStream]))

        player.handleSystemEvent(.outputLost)
        player.handleSystemEvent(.interruptionEnded(shouldResume: true))

        XCTAssertEqual(player.state, .paused("Test"))
        XCTAssertNil(player.avPlayer.currentItem)
    }

    /// tvOS pausing a video in the background is followed only when
    /// AVPlayer did stop; a stale notification must not pause live audio.
    func test_a_background_pause_counts_only_once_avplayer_stopped() {
        let player = makePlayer()
        player.play(station(streams: [liveStream]))
        XCTAssertNotEqual(player.avPlayer.rate, 0)

        player.handleSystemEvent(.pausedInBackground)
        XCTAssertEqual(player.state, .connecting("Test"))

        player.avPlayer.pause()
        player.handleSystemEvent(.pausedInBackground)
        XCTAssertEqual(player.state, .paused("Test"))
    }
}
