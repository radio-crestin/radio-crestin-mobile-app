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

    private func station(id: Int = 1, streams: [StationStream]) -> Station {
        Station(
            id: id,
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

        // Worded as on the phone's CarPlay screen.
        XCTAssertEqual(player.state, .failed("Nu s-a putut conecta la post"))
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

    // MARK: - Where the listener is on the broadcast timeline

    func test_an_hls_station_follows_its_audio_from_the_tune_in_on() {
        let player = makePlayer()

        player.play(station(streams: [liveStream]))

        XCTAssertTrue(player.followsHlsAudio)
        XCTAssertNil(player.hlsHeardDate, "nothing heard yet")
    }

    /// Paused while it connected: a resume tunes in to the same HLS stream,
    /// so its song still follows that audio, not the live timeline.
    func test_a_paused_hls_station_still_follows_its_audio() {
        let player = makePlayer()
        player.play(station(streams: [liveStream]))

        player.togglePlayPause()

        XCTAssertTrue(player.followsHlsAudio)
        XCTAssertFalse(player.isPlayingHls)
        XCTAssertNil(player.directStreamPausedAt)
    }

    func test_a_direct_stream_is_heard_live() {
        let player = makePlayer()

        player.play(station(streams: [
            StationStream(
                order: 0, type: "MP3",
                streamUrl: "http://127.0.0.1:9/live.mp3"
            ),
        ]))

        XCTAssertFalse(player.followsHlsAudio)
        XCTAssertNil(player.hlsHeardDate)
        XCTAssertNil(player.directStreamPausedAt)
    }

    /// Check, round 6: paused, a direct stream's song moved on with live.
    /// The audio stopped where it was paused, and stays there until the
    /// stream plays again, live. Check, round 7: a resume dropped it at the
    /// press, and "Melodii recente" counted from live while the stream
    /// connected, under the song still shown.
    func test_a_paused_direct_stream_stays_where_it_was_paused() async throws {
        let player = makePlayer()
        player.play(station(streams: [mp3Stream]))

        player.togglePlayPause()

        let pausedAt = try XCTUnwrap(player.directStreamPausedAt)
        XCTAssertEqual(pausedAt.timeIntervalSinceNow, 0, accuracy: 1)
        try await Task.sleep(for: .seconds(1.1))
        XCTAssertEqual(player.directStreamPausedAt, pausedAt)

        player.togglePlayPause()

        XCTAssertEqual(player.state, .connecting("Test"))
        XCTAssertEqual(
            player.directStreamPausedAt, pausedAt,
            "held until the stream plays"
        )
    }

    /// Review, round 8: a pause while a resume still connected moved the
    /// paused moment, though nothing had been heard since the first.
    func test_a_pause_while_a_resume_connects_keeps_where_the_audio_stopped() throws {
        let player = makePlayer()
        player.play(station(streams: [mp3Stream]))
        player.togglePlayPause()
        let pausedAt = try XCTUnwrap(player.directStreamPausedAt)

        player.togglePlayPause()
        XCTAssertEqual(player.stoppedAt, pausedAt, "connecting, unheard")
        player.togglePlayPause()

        XCTAssertEqual(player.directStreamPausedAt, pausedAt)
        XCTAssertEqual(player.stoppedAt, pausedAt)
    }

    func test_another_station_was_not_paused() throws {
        let player = makePlayer()
        player.play(station(streams: [mp3Stream]))
        player.togglePlayPause()
        XCTAssertNotNil(player.directStreamPausedAt)

        player.play(station(id: 2, streams: [mp3Stream]))

        XCTAssertNil(player.directStreamPausedAt)
    }

    private var mp3Stream: StationStream {
        StationStream(
            order: 0, type: "MP3",
            streamUrl: "http://127.0.0.1:9/live.mp3"
        )
    }

    /// Final check, round 2: the MP3 attempt of a retry round dropped the
    /// HLS clock as soon as it loaded. While it connected the title moved
    /// to the live song, then back when the HLS stream played again.
    func test_a_direct_stream_still_connecting_leaves_the_song_on_the_hls_audio() async throws {
        let server = try SilentServer()
        let player = makePlayer()
        player.play(hlsWithFallback(on: server))
        let hls = try XCTUnwrap(player.avPlayer.currentItem)

        postFailedToPlayToEnd(hls)

        let onMp3 = await eventually { player.avPlayer.currentItem != hls }
        XCTAssertTrue(onMp3)
        XCTAssertEqual(player.state, .connecting("Test"))
        XCTAssertTrue(player.followsHlsAudio)
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

    // MARK: - The HLS origin: start variants and the hold proxy

    /// What the engine gave AVPlayer, item by item: the origin's path,
    /// loaded directly or through the hold proxy, or the fallback stream.
    @MainActor
    private final class LoadLog {
        private let loads = Locked<[String]>([])
        private var observation: NSKeyValueObservation?

        init(_ player: AudioPlayer, origin: FakeOrigin) {
            let originPort = Int(origin.port)
            let originPath = "/http/127.0.0.1:\(origin.port)"
            observation = player.avPlayer.observe(\.currentItem) {
                [loads] avPlayer, _ in
                guard let url = (avPlayer.currentItem?.asset as? AVURLAsset)?
                    .url
                else { return }
                let load: String
                if url.port == originPort {
                    load = "direct \(url.path)"
                } else if let range = url.path.range(of: originPath) {
                    load = "proxied \(url.path[range.upperBound...])"
                } else {
                    load = "fallback \(url.path)"
                }
                loads.withValue { $0.append(load) }
            }
        }

        var all: [String] { loads.current }
    }

    /// An engine for which the fake origin, on the loopback, is the HLS
    /// origin, and what it loads.
    @MainActor
    private struct OriginRig {
        let origin: FakeOrigin
        let player: AudioPlayer
        let log: LoadLog
        /// The radio station: HLS of the origin, then an MP3 fallback that
        /// never answers, so a test sees the engine move to it and stay.
        let station: Station

        /// Waits until the engine has loaded `count` items; the loads so
        /// far.
        func loads(
            _ count: Int,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> [String] {
            let loaded = await eventually(timeout: 15) {
                log.all.count >= count
            }
            XCTAssertTrue(loaded, "loads: \(log.all)", file: file, line: line)
            return log.all
        }

        /// Waits until the station plays.
        func playing(
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let playing = await eventually(timeout: 15) { player.isPlaying }
            XCTAssertTrue(playing, "loads: \(log.all)", file: file, line: line)
        }

        /// Pauses and resumes: a new attempt, tuned in again.
        func tuneInAgain() {
            player.togglePlayPause()
            player.togglePlayPause()
        }
    }

    private nonisolated static let variant = "/hls/test/index-2m.m3u8"
    private nonisolated static let ownPlaylist = "/hls/test/index.m3u8"

    private func makeOriginRig(
        holdProxy: Bool = true
    ) async throws -> OriginRig {
        let origin = try await FakeOrigin.start()
        let fallback = try SilentServer()
        let player = AudioPlayer(
            reportError: { _, _, _ in },
            originHosts: ["127.0.0.1"],
            isHoldProxyEnabled: { holdProxy }
        )
        addTeardownBlock {
            player.stop()
            origin.close()
            withExtendedLifetime(fallback) {}
        }
        let station = self.station(streams: [
            StationStream(
                order: 0, type: "HLS",
                streamUrl: origin.url(Self.ownPlaylist).absoluteString
            ),
            fallback.stream("MP3", at: "/live.mp3", order: 1),
        ])
        return OriginRig(
            origin: origin,
            player: player,
            log: LoadLog(player, origin: origin),
            station: station
        )
    }

    func test_the_origin_starts_at_its_start_variant_through_the_hold_proxy() async throws {
        let rig = try await makeOriginRig()
        rig.origin.handler = { FakeOrigin.playableStream($0) }

        rig.player.play(rig.station)

        let loads = await rig.loads(1)
        XCTAssertEqual(loads.first, "proxied \(Self.variant)")
    }

    func test_with_the_kill_switch_off_the_origin_loads_directly() async throws {
        let rig = try await makeOriginRig(holdProxy: false)

        rig.player.play(rig.station)

        XCTAssertEqual(rig.log.all, ["direct \(Self.variant)"])
    }

    /// Review: both playlists answered 404 for a moment (a pod
    /// restarting). Remembering the variant as missing then cost the
    /// station its 2-minute offset until the app was relaunched.
    func test_a_variant_not_found_is_tried_again_when_its_own_playlist_fails_too() async throws {
        let rig = try await makeOriginRig()
        rig.origin.handler = { _ in FakeOrigin.Response(status: 404) }
        rig.player.play(rig.station)
        // The origin answered: neither is the hold proxy's failure.
        let first = await rig.loads(3)
        XCTAssertEqual(first, [
            "proxied \(Self.variant)",
            "proxied \(Self.ownPlaylist)",
            "fallback /live.mp3",
        ])

        rig.tuneInAgain()

        let loads = await rig.loads(4)
        XCTAssertEqual(loads[3], "proxied \(Self.variant)")
    }

    func test_a_variant_not_found_is_skipped_once_its_own_playlist_loads() async throws {
        let rig = try await makeOriginRig()
        rig.origin.handler = { request in
            request.path == Self.variant
                ? FakeOrigin.Response(status: 404)
                : FakeOrigin.playableStream(request)
        }
        rig.player.play(rig.station)
        await rig.playing()

        rig.tuneInAgain()

        let loads = await rig.loads(3)
        XCTAssertEqual(loads.prefix(3), [
            "proxied \(Self.variant)",
            "proxied \(Self.ownPlaylist)",
            "proxied \(Self.ownPlaylist)",
        ])
    }

    /// The origin out of reach: the load through the proxy and the direct
    /// one both fail, so the stream keeps the proxy.
    func test_a_load_through_the_proxy_the_origin_never_answered_loads_directly_in_the_same_attempt() async throws {
        let rig = try await makeOriginRig()
        rig.origin.mode = .droppingConnections
        rig.player.play(rig.station)
        let first = await rig.loads(3)
        XCTAssertEqual(first, [
            "proxied \(Self.variant)",
            "direct \(Self.variant)",
            "fallback /live.mp3",
        ])

        rig.tuneInAgain()

        let loads = await rig.loads(4)
        XCTAssertEqual(loads[3], "proxied \(Self.variant)")
    }

    func test_a_load_the_origin_answered_through_the_proxy_is_no_proxy_failure() async throws {
        let rig = try await makeOriginRig()
        rig.origin.handler = { _ in FakeOrigin.Response(status: 503) }

        rig.player.play(rig.station)

        let loads = await rig.loads(2)
        XCTAssertEqual(loads, [
            "proxied \(Self.variant)",
            "fallback /live.mp3",
        ])
    }

    /// The proxy's own way to the origin fails (its upstream requests are
    /// URLSession's, `Accept-Encoding: gzip, deflate`; AVPlayer's own send
    /// `gzip`, measured on the tvOS 27 simulator), the direct one works.
    private func failTheProxysWay(of origin: FakeOrigin) {
        origin.handler = { request in
            request.headers["accept-encoding"]?.contains("deflate") == true
                ? .dropped
                : FakeOrigin.playableStream(request)
        }
    }

    func test_a_stream_that_played_directly_after_the_proxy_failed_skips_the_proxy() async throws {
        let rig = try await makeOriginRig()
        failTheProxysWay(of: rig.origin)
        rig.player.play(rig.station)
        await rig.playing()

        rig.tuneInAgain()

        let loads = await rig.loads(3)
        XCTAssertEqual(loads.prefix(3), [
            "proxied \(Self.variant)",
            "direct \(Self.variant)",
            "direct \(Self.variant)",
        ])
    }

    func test_the_network_coming_back_or_changing_gives_the_proxy_another_chance() async throws {
        let rig = try await makeOriginRig()
        failTheProxysWay(of: rig.origin)
        rig.player.play(rig.station)
        await rig.playing()

        rig.player.networkChanged()
        rig.tuneInAgain()

        var loads = await rig.loads(4)
        XCTAssertEqual(loads[2], "proxied \(Self.variant)")
        XCTAssertEqual(loads[3], "direct \(Self.variant)", "failed again")
        await rig.playing()

        rig.player.networkRestored()
        rig.tuneInAgain()

        loads = await rig.loads(5)
        XCTAssertEqual(loads[4], "proxied \(Self.variant)")
    }

    // MARK: - How far behind live a paused station is

    /// What the origin serves for a stream heard `lag` seconds behind live:
    /// the playable stream, its playlist dating the first segment then.
    private static func stream(
        heardBehindLive lag: TimeInterval
    ) -> (FakeOrigin.Request) -> FakeOrigin.Response? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.string(from: Date().addingTimeInterval(-lag))
        let playlist = FakeOrigin.vodPlaylist(segments: 60).replacingOccurrences(
            of: "#EXT-X-PLAYLIST-TYPE:VOD\n",
            with: "#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-PROGRAM-DATE-TIME:\(start)\n"
        )
        return { request in
            guard request.path.hasSuffix(".m3u8") else {
                return FakeOrigin.playableStream(request)
            }
            return FakeOrigin.Response(
                headers: [("Content-Type", "application/vnd.apple.mpegurl")],
                body: Data(playlist.utf8)
            )
        }
    }

    /// How far behind live the engine puts the listener, in seconds.
    private func heardLag(_ player: AudioPlayer) throws -> TimeInterval {
        Date().timeIntervalSince(try XCTUnwrap(player.hlsHeardDate))
    }

    /// Review C2: a pause dropped the item, and the song shown moved to
    /// the live one. Then the paused clock moved on with live, and a full
    /// refresh put a song never heard on screen. Paused, the listener
    /// stays where they were heard, until the stream plays again.
    func test_a_paused_station_stays_where_it_was_heard() async throws {
        let rig = try await makeOriginRig()
        rig.origin.handler = Self.stream(heardBehindLive: 120)
        rig.player.play(rig.station)
        await rig.playing()
        let playing = try heardLag(rig.player)
        XCTAssertEqual(playing, 120, accuracy: 10)

        rig.player.togglePlayPause()

        XCTAssertEqual(rig.player.state, .paused("Test"))
        XCTAssertTrue(rig.player.followsHlsAudio)
        XCTAssertEqual(try heardLag(rig.player), playing, accuracy: 2)
        let pausedAt = try XCTUnwrap(rig.player.hlsHeardDate)
        try await Task.sleep(for: .seconds(1.1))
        XCTAssertEqual(rig.player.hlsHeardDate, pausedAt)

        rig.player.togglePlayPause()

        XCTAssertEqual(rig.player.state, .connecting("Test"))
        XCTAssertEqual(rig.player.hlsHeardDate, pausedAt)
    }

    /// Review, round 9: a resume onto a playlist gone stale took its lag
    /// and dropped the paused moment before the engine turned it down: the
    /// song shown moved minutes back, to a moment never heard.
    func test_a_stale_join_keeps_where_the_audio_stopped() async throws {
        let rig = try await makeOriginRig()
        rig.origin.handler = Self.stream(heardBehindLive: 120)
        rig.player.play(rig.station)
        await rig.playing()
        rig.player.togglePlayPause()
        let pausedAt = try XCTUnwrap(rig.player.hlsHeardDate)
        rig.origin.handler = Self.stream(heardBehindLive: 900)

        rig.player.togglePlayPause()

        let turnedDown = await eventually(timeout: 15) {
            rig.log.all.last == "fallback /live.mp3"
        }
        XCTAssertTrue(turnedDown, "loads: \(rig.log.all)")
        XCTAssertEqual(rig.player.hlsHeardDate, pausedAt)
        XCTAssertEqual(rig.player.stoppedAt, pausedAt)
    }

    func test_the_fallback_to_a_direct_stream_is_heard_live_once_it_plays() async throws {
        let rig = try await makeOriginRig()
        // The origin refuses the HLS playlists and serves the fallback, a
        // direct stream as the catalog lists it (AVPlayer plays whatever
        // the catalog calls it).
        rig.origin.handler = { request in
            request.path.hasPrefix("/hls/")
                ? FakeOrigin.Response(status: 404)
                : FakeOrigin.playableStream(request)
        }
        let fallback = StationStream(
            order: 1, type: "MP3",
            streamUrl: rig.origin.url("/direct/index.m3u8").absoluteString
        )

        rig.player.play(station(streams: [rig.station.stationStreams[0], fallback]))

        XCTAssertTrue(rig.player.followsHlsAudio)
        await rig.playing()
        XCTAssertFalse(rig.player.followsHlsAudio)
        XCTAssertNil(rig.player.hlsHeardDate)
    }

    func test_another_offset_or_station_starts_somewhere_else() async throws {
        let rig = try await makeOriginRig()
        rig.origin.handler = Self.stream(heardBehindLive: 120)
        rig.player.play(rig.station)
        await rig.playing()
        rig.player.togglePlayPause()
        let pausedAt = try XCTUnwrap(rig.player.hlsHeardDate)

        rig.player.setSeekMode(.fiveMinutes)

        // Paused, the song shown stays the one heard.
        XCTAssertTrue(rig.player.followsHlsAudio)
        XCTAssertEqual(rig.player.hlsHeardDate, pausedAt)

        // Resumed, the stream at the new offset is heard elsewhere, not
        // known yet: until it plays, the song shown stays the one heard
        // (review, round 9: it moved to the new offset at the press).
        rig.player.togglePlayPause()
        XCTAssertEqual(rig.player.hlsHeardDate, pausedAt)
        XCTAssertEqual(rig.player.stoppedAt, pausedAt)

        rig.player.setSeekMode(.twoMinutes)
        await rig.playing()

        rig.player.play(station(id: 2, streams: rig.station.stationStreams))

        XCTAssertTrue(rig.player.followsHlsAudio)
        XCTAssertNil(rig.player.hlsHeardDate)
    }
}
