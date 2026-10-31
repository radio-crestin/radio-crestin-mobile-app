import XCTest
@testable import RadioCrestinTV

/// What the listener sees about the song follows what they hear: on an HLS
/// station played behind live, the title and "Melodii recente" follow the
/// audio while it plays, connects and is paused; a direct stream follows
/// the live timeline. And the sync engine never loses the fetch at the
/// audio's moment.
///
/// `AppState` loads from a stubbed API, and its providers stand in for the
/// audio engine. It reports listening nowhere, so a test can tune in with
/// `selectStation`; others make a station the current one directly.
@MainActor
final class SongClockTests: XCTestCase {

    private let stationId = 7

    private static let historyPath = "/api/v1/stations-metadata-history"

    /// An `AppState` on its own defaults and the stubbed API, in `mode`.
    private func makeAppState(_ mode: SeekMode = .twoMinutes) -> AppState {
        let suite = "SongClockTests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suite)
            StubAPIProtocol.reset()
        }
        let appState = AppState(
            repository: StubAPIProtocol.repository(),
            defaults: UserDefaults(suiteName: suite) ?? .standard,
            catalogCache: StationCatalogCache(fileURL: nil),
            reportListening: { _, _ in }
        )
        appState.seekMode = mode
        return appState
    }

    /// The paths asked for since `count` requests.
    private func paths(after count: Int) -> [String] {
        StubAPIProtocol.requestedURLs.dropFirst(count).map(\.path)
    }

    /// Waits until the song history was asked for `times` times since
    /// `count` requests.
    private func historyFetched(
        _ times: Int = 1,
        after count: Int
    ) async -> Bool {
        await eventually {
            paths(after: count).filter { $0 == Self.historyPath }.count >= times
        }
    }

    /// The API's timestamp of the moment `seconds` ago.
    private func stamp(ago seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(-seconds))
    }

    /// Radio Eldad, HLS with an MP3 fallback, playing `song` since
    /// `startedAgo` seconds as the catalog says.
    private func eldad(song: String, startedAgo: TimeInterval) -> Station {
        radio(id: stationId, slug: "eldad", song: song, startedAgo: startedAgo)
    }

    /// A radio station like Eldad, HLS with an MP3 fallback (`stationType`
    /// "tv" makes it a TV station).
    private func radio(
        id: Int,
        slug: String,
        song: String,
        songId: Int = 1,
        startedAgo: TimeInterval,
        stationType: String? = nil
    ) -> Station {
        Station(
            id: id,
            slug: slug,
            title: slug.capitalized,
            order: 0,
            thumbnailUrl: nil,
            totalListeners: 10,
            stationStreams: [
                StationStream(order: 0, type: "HLS",
                              streamUrl: "https://x/eldad/index.m3u8"),
                StationStream(order: 1, type: "MP3",
                              streamUrl: "https://x/eldad.mp3"),
            ],
            uptime: Uptime(isUp: true, timestamp: nil),
            nowPlaying: NowPlaying(
                id: 1,
                timestamp: stamp(ago: startedAgo),
                song: Song(id: songId, name: song, thumbnailUrl: nil, artist: nil)
            ),
            reviewsStats: nil,
            stationType: stationType,
            playlistItems: nil,
            hlsDvrStreamUrl: nil
        )
    }

    /// Eldad's entry in a live `/stations-metadata` payload.
    private func live(
        song: String,
        songId: Int = 2,
        listeners: Int = 12,
        startedAgo: TimeInterval
    ) -> [String: Any] {
        [
            "id": stationId,
            "uptime": ["is_up": true],
            "now_playing": [
                "timestamp": stamp(ago: startedAgo),
                "listeners": listeners,
                "song": ["id": songId, "name": song],
            ],
        ]
    }

    /// Makes `station` the one playing, as the engine reports it: its song
    /// following HLS audio heard `heardLag` seconds behind live (nil while
    /// nothing is heard yet: a tune-in), or paused where the audio was at
    /// `pausedAt`, or with `followsHls` false, the live timeline (a direct
    /// stream), paused at `pausedAt` too.
    private func play(
        _ station: Station,
        in appState: AppState,
        followsHls: Bool = true,
        heardLag: TimeInterval? = nil,
        pausedAt: Date? = nil
    ) {
        appState.followsHlsAudioProvider = { followsHls }
        appState.hlsHeardDateProvider = {
            guard followsHls else { return nil }
            return pausedAt ?? heardLag.map { Date().addingTimeInterval(-$0) }
        }
        appState.directStreamPausedAtProvider = {
            followsHls ? nil : pausedAt
        }
        appState.isPlaybackPaused = pausedAt != nil
        appState.currentStation = station
    }

    private func recentTitles(_ appState: AppState) -> [String] {
        appState.songHistory.entries(for: "eldad").map(\.title)
    }

    private func query(_ name: String, of url: URL?) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == name }?.value
    }

    // MARK: - Paused (review C2)

    /// A pause drops the item, and the next sync took the live song the
    /// audio, two minutes behind, had not reached.
    func test_pausing_keeps_the_song_the_audio_was_in() async throws {
        let appState = makeAppState()
        let station = eldad(song: "A", startedAgo: 200)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        play(station, in: appState, heardLag: 120)
        try StubAPIProtocol.serveMetadata([live(song: "B", startedAgo: 60)])

        await appState.enqueueSync(.periodic)

        XCTAssertEqual(appState.currentStation?.songTitle, "A")
        XCTAssertEqual(recentTitles(appState), ["A"])
    }

    /// Waiting to reconnect, the audio the reconnect rejoins moves on with
    /// the clock.
    func test_a_station_reconnecting_moves_on_when_its_audio_would_have() async throws {
        let appState = makeAppState()
        let station = eldad(song: "A", startedAgo: 400)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        play(station, in: appState, heardLag: 120)
        try StubAPIProtocol.serveMetadata([live(song: "B", startedAgo: 150)])

        await appState.enqueueSync(.periodic)

        XCTAssertEqual(appState.currentStation?.songTitle, "B")
    }

    /// Final check, round 2: paused, a full refresh (back to the app) put
    /// the song the audio would have reached by then on screen and in the
    /// system's Now Playing, a song never heard. Paused, the song shown
    /// stays the one heard, as in Apple Music.
    func test_a_paused_station_keeps_its_song_through_a_full_refresh() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "A", startedAgo: 400)])
        await appState.loadStations()
        let station = try XCTUnwrap(appState.stations.first)
        play(station, in: appState, pausedAt: Date().addingTimeInterval(-300))
        try StubAPIProtocol.serve([eldad(song: "B", startedAgo: 150)])

        await appState.enqueueSync(.appResumed)

        XCTAssertEqual(appState.currentStation?.songTitle, "A")
    }

    func test_a_direct_stream_follows_the_live_song() async throws {
        let appState = makeAppState()
        let station = eldad(song: "A", startedAgo: 200)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        play(station, in: appState, followsHls: false)
        try StubAPIProtocol.serveMetadata([live(song: "B", startedAgo: 60)])

        await appState.enqueueSync(.periodic)

        XCTAssertEqual(appState.currentStation?.songTitle, "B")
    }

    /// Check, round 6: a paused MP3 station showed the song the live
    /// timeline moved to, on screen and in the system's Now Playing, and
    /// moved the one heard to "Melodii recente". Paused, a direct stream
    /// keeps the song heard; resumed, it plays live again.
    func test_a_paused_direct_stream_keeps_the_song_heard() async throws {
        let appState = makeAppState()
        let station = eldad(song: "A", startedAgo: 200)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        play(station, in: appState, followsHls: false,
             pausedAt: Date().addingTimeInterval(-30))
        try StubAPIProtocol.serveMetadata([live(song: "B", startedAgo: 10)])

        await appState.enqueueSync(.periodic)

        XCTAssertEqual(appState.currentStation?.songTitle, "A")
        XCTAssertEqual(recentTitles(appState), ["A"])

        play(appState.currentStation ?? station, in: appState, followsHls: false)
        await appState.refreshMetadataNow()

        XCTAssertEqual(appState.currentStation?.songTitle, "B")
    }

    /// The song that started before the pause was heard, even when the
    /// poll brought it only after.
    func test_a_paused_direct_stream_takes_the_song_it_was_paused_in() async throws {
        let appState = makeAppState()
        let station = eldad(song: "A", startedAgo: 200)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        play(station, in: appState, followsHls: false,
             pausedAt: Date().addingTimeInterval(-5))
        try StubAPIProtocol.serveMetadata([live(song: "B", startedAgo: 10)])

        await appState.enqueueSync(.periodic)

        XCTAssertEqual(appState.currentStation?.songTitle, "B")
    }

    // MARK: - Tuning in (review C3)

    /// Two minutes behind live, the catalog's song a minute old is still
    /// ahead of the listener: no song, rather than one that flips back.
    func test_a_tune_in_shows_no_song_the_audio_has_not_reached() async throws {
        let appState = makeAppState()
        let station = eldad(song: "L", startedAgo: 60)
        try StubAPIProtocol.serve([station])
        play(station, in: appState)

        await appState.loadStations()

        XCTAssertEqual(appState.currentStation?.songTitle, "")
        XCTAssertEqual(recentTitles(appState), [])
    }

    func test_a_tune_in_shows_the_play_the_history_puts_the_audio_in() async throws {
        let appState = makeAppState()
        let station = eldad(song: "L", startedAgo: 60)
        appState.songHistory.seed([
            SongEntry(title: "L", artist: "",
                      timestamp: Date().addingTimeInterval(-60)),
            SongEntry(title: "P", artist: "",
                      timestamp: Date().addingTimeInterval(-300)),
        ], for: "eldad")
        try StubAPIProtocol.serve([station])
        play(station, in: appState)

        await appState.loadStations()

        XCTAssertEqual(appState.currentStation?.songTitle, "P")
        XCTAssertEqual(recentTitles(appState), ["P"])
    }

    /// Final check, round 2: tuned in 128 s after a song change, the
    /// estimate put the audio in the song before it, which showed for
    /// 0.7 s before the one heard. A change within the estimate's spread
    /// leaves the song unknown until the audio's own payload comes.
    func test_a_tune_in_near_a_song_change_shows_neither_song() async throws {
        let appState = makeAppState()
        let station = eldad(song: "N", startedAgo: 60)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        appState.songHistory.seed([
            SongEntry(title: "N", artist: "",
                      timestamp: Date().addingTimeInterval(-60)),
            SongEntry(title: "L", artist: "",
                      timestamp: Date().addingTimeInterval(-125)),
            SongEntry(title: "P", artist: "",
                      timestamp: Date().addingTimeInterval(-300)),
        ], for: "eldad")

        appState.selectStation(station)

        XCTAssertEqual(appState.currentStation?.songTitle, "")
    }

    func test_a_tune_in_well_after_a_song_change_shows_the_song() async throws {
        let appState = makeAppState()
        let station = eldad(song: "N", startedAgo: 60)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        appState.songHistory.seed([
            SongEntry(title: "N", artist: "",
                      timestamp: Date().addingTimeInterval(-60)),
            SongEntry(title: "L", artist: "",
                      timestamp: Date().addingTimeInterval(-150)),
        ], for: "eldad")

        appState.selectStation(station)

        XCTAssertEqual(appState.currentStation?.songTitle, "L")
    }

    /// Review, round 2: opened again before the first merge, the playing
    /// station took the grid's copy, whose live song the audio had not
    /// reached, and the next merge took it back.
    func test_opening_the_playing_station_again_keeps_its_song() async throws {
        let appState = makeAppState()
        let station = eldad(song: "L", startedAgo: 60)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        appState.selectStation(station)
        XCTAssertEqual(appState.currentStation?.songTitle, "")

        appState.selectStation(station)

        XCTAssertEqual(appState.currentStation?.songTitle, "")
        XCTAssertEqual(recentTitles(appState), [])
    }

    // MARK: - The station's history at a tune-in

    /// Final check, round 2: the song a tune-in shows was recorded before
    /// the fetch was decided and counted as history, so the history was
    /// never fetched and "Melodii recente" stayed empty all session.
    func test_a_tune_in_that_shows_a_song_fetches_the_station_history() async throws {
        let appState = makeAppState(.instant)
        let station = eldad(song: "L", startedAgo: 60)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        let before = StubAPIProtocol.requestedURLs.count

        appState.selectStation(station)

        XCTAssertEqual(appState.currentStation?.songTitle, "L")
        let fetched = await historyFetched(after: before)
        XCTAssertTrue(fetched, "\(paths(after: before))")
    }

    /// Tunes in to `station` and waits until the tune-in's history fetch
    /// and full refresh, and whatever they started, are done.
    private func tuneIn(_ station: Station, in appState: AppState) async {
        let before = StubAPIProtocol.requestedURLs.count
        appState.selectStation(station)
        let fetched = await historyFetched(after: before)
        let isIdle = await eventually { !appState.isLoading }
        await letQueuedWorkRun()
        XCTAssertTrue(fetched && isIdle, "\(paths(after: before))")
    }

    /// A history the API did not answer at the tune-in (out of reach) is
    /// asked for again at the next sync, until it comes.
    func test_a_history_fetch_that_went_unanswered_is_tried_again_at_the_next_sync() async throws {
        let appState = makeAppState()
        let station = eldad(song: "L", startedAgo: 60)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        StubAPIProtocol.setUnreachable(Self.historyPath)
        await tuneIn(station, in: appState)
        StubAPIProtocol.setUnreachable(Self.historyPath, false)
        let before = StubAPIProtocol.requestedURLs.count

        await appState.enqueueSync(.periodic)

        let again = await historyFetched(after: before)
        XCTAssertTrue(again, "\(paths(after: before))")
    }

    /// Review, round 3: an answer that is no history (the API answers a
    /// station it does not know with an error) blanked the station all
    /// session. It is asked for again at the next tune-in, not at every
    /// sync.
    func test_a_history_the_api_refused_is_asked_again_at_the_next_tune_in() async throws {
        let appState = makeAppState()
        let station = eldad(song: "L", startedAgo: 60)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        // The stub answers the history with 404.
        await tuneIn(station, in: appState)
        let before = StubAPIProtocol.requestedURLs.count

        await appState.enqueueSync(.periodic)
        await letQueuedWorkRun()
        XCTAssertFalse(paths(after: before).contains(Self.historyPath))

        appState.selectStation(station)

        let again = await historyFetched(after: before)
        XCTAssertTrue(again, "\(paths(after: before))")
    }

    func test_a_current_history_is_not_fetched_again() async throws {
        let appState = makeAppState()
        let station = eldad(song: "L", startedAgo: 60)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        appState.songHistory.seed([], for: "eldad")
        let before = StubAPIProtocol.requestedURLs.count

        appState.selectStation(station)
        await appState.enqueueSync(.periodic)
        await letQueuedWorkRun()

        XCTAssertFalse(paths(after: before).contains(Self.historyPath))
    }

    /// Review, round 3: opened again hours later, a station kept the plays
    /// of its last visit under the song now on, with the gap between.
    func test_a_history_loaded_long_ago_is_fetched_again_at_a_tune_in() async throws {
        let appState = makeAppState()
        let station = eldad(song: "L", startedAgo: 60)
        try StubAPIProtocol.serve([station])
        await appState.loadStations()
        appState.songHistory.seed(
            [], for: "eldad", at: Date().addingTimeInterval(-11 * 60)
        )
        let before = StubAPIProtocol.requestedURLs.count

        appState.selectStation(station)

        let fetched = await historyFetched(after: before)
        XCTAssertTrue(fetched, "\(paths(after: before))")
    }

    /// Live, the audio is at most 30 s behind: a song a minute old is heard.
    func test_live_mode_shows_a_song_the_audio_can_have_reached() async throws {
        let appState = makeAppState(.instant)
        let station = eldad(song: "L", startedAgo: 60)
        try StubAPIProtocol.serve([station])
        play(station, in: appState)

        await appState.loadStations()

        XCTAssertEqual(appState.currentStation?.songTitle, "L")
    }

    // MARK: - "Melodii recente" times (review C1)

    /// How far behind live the heard clock is at this moment.
    private func heardLag(_ appState: AppState) -> TimeInterval {
        let now = Date()
        return now.timeIntervalSince(appState.heardClock.heardNow(at: now))
    }

    /// The times count back from where the title's clock puts the audio:
    /// the middle of the estimate while it connects (135 s to 114 s behind
    /// live in the 2 minute mode), how far behind live it is heard while
    /// it plays, now on the live clock.
    func test_the_heard_clock_is_the_song_clocks() {
        let appState = makeAppState()
        let station = eldad(song: "A", startedAgo: 200)
        XCTAssertEqual(appState.heardClock, .behindLive(0), "nothing playing")

        play(station, in: appState)
        XCTAssertEqual(heardLag(appState), 124.5, accuracy: 1)

        play(station, in: appState, heardLag: 121.5)
        XCTAssertEqual(heardLag(appState), 121.5, accuracy: 1)

        play(station, in: appState, followsHls: false)
        XCTAssertEqual(appState.heardClock, .behindLive(0))

        appState.seekMode = .instant
        play(station, in: appState)
        XCTAssertEqual(heardLag(appState), 22.5, accuracy: 1)

        appState.seekMode = .fiveMinutes
        XCTAssertEqual(heardLag(appState), 304.5, accuracy: 1)
    }

    /// Check, round 6: paused, the times climbed a minute and fell back
    /// with every poll: the lag behind live, read at a redraw, grew while
    /// the 10 s timer counted back from it. Paused, they count back from
    /// the moment the audio stopped at.
    func test_paused_the_times_count_back_from_where_the_audio_stopped() {
        let appState = makeAppState()
        let station = eldad(song: "A", startedAgo: 200)
        let pausedAt = Date().addingTimeInterval(-300)
        let later = Date().addingTimeInterval(600)

        play(station, in: appState, pausedAt: pausedAt)
        XCTAssertEqual(appState.heardClock, .stopped(at: pausedAt))
        XCTAssertEqual(appState.heardClock.heardNow(at: later), pausedAt)

        play(station, in: appState, followsHls: false, pausedAt: pausedAt)
        XCTAssertEqual(appState.heardClock, .stopped(at: pausedAt))
    }

    // MARK: - The fetch at the audio's moment (review C4)

    /// An audio event in the 10-minute window was promoted to a full
    /// refresh, which asks about the live timeline: the song the audio had
    /// just reached waited for the next change.
    func test_an_audio_event_after_the_full_refresh_window_asks_about_the_audio() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "A", startedAgo: 200)])
        await appState.loadStations()
        appState.hlsPlaybackTimestampProvider = { 1_793_395_780 }
        appState.lastFullRefresh = Date().addingTimeInterval(-11 * 60)
        let before = StubAPIProtocol.requestedURLs.count

        await appState.refreshMetadataNow()

        let requests = Array(StubAPIProtocol.requestedURLs.dropFirst(before))
        XCTAssertEqual(requests.map(\.path), ["/api/v1/stations-metadata"])
        XCTAssertEqual(query("timestamp", of: requests.first), "1793395780")
    }

    /// Final check, round 2: the API out of reach as the audio reached a
    /// song change, and nothing asked again: the title waited for the
    /// next change.
    func test_an_audio_fetch_that_failed_is_asked_again_at_the_next_tick() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "A", startedAgo: 200)])
        await appState.loadStations()
        appState.hlsPlaybackTimestampProvider = { 1_793_395_780 }
        appState.isPlayingHlsProvider = { true }
        StubAPIProtocol.setUnreachable("/api/v1/stations-metadata")
        await appState.refreshMetadataNow()
        StubAPIProtocol.setUnreachable("/api/v1/stations-metadata", false)
        let before = StubAPIProtocol.requestedURLs.count

        await appState.enqueueSync(.periodic)

        let aligned = StubAPIProtocol.requestedURLs.dropFirst(before).filter {
            query("timestamp", of: $0) == "1793395780"
        }
        XCTAssertEqual(aligned.map(\.path), ["/api/v1/stations-metadata"])
    }

    func test_the_periodic_tick_runs_the_full_refresh_that_is_due() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "A", startedAgo: 200)])
        await appState.loadStations()
        appState.lastFullRefresh = Date().addingTimeInterval(-11 * 60)
        let before = StubAPIProtocol.requestedURLs.count

        await appState.enqueueSync(.periodic)

        let paths = StubAPIProtocol.requestedURLs.dropFirst(before).map(\.path)
        XCTAssertTrue(paths.contains("/api/v1/stations"), "\(paths)")
    }

    /// An audio event that came while a sync ran and a full refresh was
    /// queued coalesced into it and was lost: a full refresh fetches only
    /// the live timeline.
    func test_an_audio_event_is_not_lost_behind_a_queued_full_refresh() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "A", startedAgo: 200)])
        await appState.loadStations()
        appState.hlsPlaybackTimestampProvider = { 1_793_395_780 }
        StubAPIProtocol.answer(after: 0.3)
        let before = StubAPIProtocol.requestedURLs.count
        let inFlight = Task { await appState.enqueueSync(.appResumed) }
        let isSyncing = await eventually { appState.isLoading }
        XCTAssertTrue(isSyncing)

        await appState.enqueueSync(.stationPlayed)
        await appState.refreshMetadataNow()
        await inFlight.value

        let aligned = StubAPIProtocol.requestedURLs.dropFirst(before).filter {
            query("timestamp", of: $0) == "1793395780"
        }
        XCTAssertEqual(aligned.map(\.path), ["/api/v1/stations-metadata"])
    }

    /// Review, round 7: a direct stream's audio start asked for a diff from
    /// the last audio fetch. One made while the stream was paused left out
    /// the station, whose song had changed before it, and the song heard
    /// before the pause stayed after the resume.
    func test_a_direct_streams_audio_start_asks_for_the_whole_live_timeline() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "A", startedAgo: 200)])
        await appState.loadStations()
        appState.hlsPlaybackTimestampProvider = { roundedTimestamp() - 30 }
        await appState.refreshMetadataNow()
        appState.hlsPlaybackTimestampProvider = { nil }
        let before = StubAPIProtocol.requestedURLs.count

        await appState.refreshMetadataNow()

        let requests = Array(StubAPIProtocol.requestedURLs.dropFirst(before))
        XCTAssertEqual(requests.map(\.path), ["/api/v1/stations-metadata"])
        XCTAssertNil(query("changes_from_timestamp", of: requests.first))
    }

    // MARK: - A song on its way (round 8)

    /// Check, round 8: a tune-in whose live song began within the 21 s
    /// the audio's start can fall in showed the station's name as the
    /// title, then the song once the audio told which one it is.
    func test_a_tune_in_that_cannot_tell_its_song_awaits_it() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "L", startedAgo: 125)])
        await appState.loadStations()
        let listed = try XCTUnwrap(appState.stations.first)
        let before = StubAPIProtocol.requestedURLs.count

        appState.selectStation(listed)

        XCTAssertTrue(appState.isAwaitingSong)
        XCTAssertNil(appState.currentStation?.nowPlaying)
        let refreshed = await eventually {
            self.paths(after: before).contains("/api/v1/stations")
                && !appState.isLoading
        }
        XCTAssertTrue(refreshed)
        XCTAssertTrue(appState.isAwaitingSong, "the live timeline cannot tell")

        try StubAPIProtocol.serveMetadata([live(song: "L", startedAgo: 125)])
        playsHls(in: appState, heardLag: 120)
        await appState.refreshMetadataNow()

        XCTAssertEqual(appState.currentStation?.songTitle, "L")
        XCTAssertFalse(appState.isAwaitingSong)
    }

    /// The audio's moment asked about and still no song: none is known,
    /// and the station's name takes the title. The audio, 120 s behind,
    /// has not reached the live song, 115 s old.
    func test_a_song_the_audio_cannot_tell_is_awaited_no_longer() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "L", startedAgo: 115)])
        await appState.loadStations()
        let before = StubAPIProtocol.requestedURLs.count
        appState.selectStation(try XCTUnwrap(appState.stations.first))
        XCTAssertTrue(appState.isAwaitingSong)
        let refreshed = await tuneInRefreshed(appState, after: before)
        XCTAssertTrue(refreshed)

        StubAPIProtocol.setUnreachable("/api/v1/stations-metadata")
        playsHls(in: appState, heardLag: 120)
        await appState.refreshMetadataNow()

        XCTAssertFalse(appState.isAwaitingSong)
        XCTAssertEqual(appState.currentStation?.songTitle, "")
    }

    /// Check, round 9: with the refresh at the tune-in failed, the answer
    /// for the audio's moment brought the song the grid's copy already
    /// had, the list did not change, and Now Playing named the station
    /// for 20 s while the song played.
    func test_a_tune_in_whose_refresh_failed_shows_the_song_the_audio_brings() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "L", startedAgo: 125)])
        await appState.loadStations()
        StubAPIProtocol.setUnreachable("/api/v1/stations")
        let before = StubAPIProtocol.requestedURLs.count
        appState.selectStation(try XCTUnwrap(appState.stations.first))
        let refreshed = await tuneInRefreshed(appState, after: before)
        XCTAssertTrue(refreshed)
        XCTAssertTrue(appState.isAwaitingSong)

        try StubAPIProtocol.serveMetadata([live(song: "L", startedAgo: 125)])
        playsHls(in: appState, heardLag: 120)
        await appState.refreshMetadataNow()

        XCTAssertEqual(appState.currentStation?.songTitle, "L")
        XCTAssertFalse(appState.isAwaitingSong)
    }

    /// Review, round 9: the answer for the audio of the station playing
    /// before a quick next was taken as the next station's own, which
    /// showed a song from the wrong moment, then the right one.
    func test_an_audio_answer_for_the_station_before_is_not_the_next_ones() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([
            eldad(song: "A", startedAgo: 600),
            radio(id: 2, slug: "b", song: "L", startedAgo: 125),
        ])
        await appState.loadStations()
        let first = try XCTUnwrap(appState.stations.first { $0.id == stationId })
        let next = try XCTUnwrap(appState.stations.first { $0.id == 2 })
        let before = StubAPIProtocol.requestedURLs.count
        appState.selectStation(first)
        let refreshed = await tuneInRefreshed(appState, after: before)
        XCTAssertTrue(refreshed)
        // The answer for that moment, which names another song for the
        // next station, as fresh as its live one: the live timeline cannot
        // tell the next station's song.
        try StubAPIProtocol.serveMetadata([
            ["id": 2, "uptime": ["is_up": true], "now_playing": [
                "timestamp": stamp(ago: 125), "song": ["id": 7, "name": "X"],
            ]],
        ])
        playsHls(in: appState, heardLag: 120)
        StubAPIProtocol.answer(after: 0.3)
        let asked = StubAPIProtocol.requestedURLs.count
        let fetch = Task { await appState.refreshMetadataNow() }
        let sent = await eventually {
            StubAPIProtocol.requestedURLs.count > asked
        }
        XCTAssertTrue(sent)

        appState.hlsHeardDateProvider = { nil }
        appState.selectStation(next)
        await fetch.value

        XCTAssertEqual(appState.currentStation?.id, 2)
        XCTAssertTrue(appState.isAwaitingSong)
        XCTAssertEqual(appState.currentStation?.songTitle, "")
    }

    func test_a_pause_ends_the_wait_for_the_song() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "L", startedAgo: 125)])
        await appState.loadStations()
        appState.selectStation(try XCTUnwrap(appState.stations.first))
        XCTAssertTrue(appState.isAwaitingSong)

        appState.isPlaybackPaused = true

        XCTAssertFalse(appState.isAwaitingSong)
    }

    /// A tune-in that knows its song, or one to a station heard live,
    /// awaits nothing.
    func test_a_tune_in_that_knows_its_song_awaits_nothing() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([
            eldad(song: "P", startedAgo: 600),
            radio(id: 2, slug: "tv", song: "M", startedAgo: 125,
                  stationType: "tv"),
        ])
        await appState.loadStations()

        for station in appState.stations {
            appState.selectStation(station)
            XCTAssertFalse(appState.isAwaitingSong, station.slug)
        }
    }

    /// Review, round 8: a resume still connecting counted the times on
    /// from where the audio stopped, and they climbed a minute and fell
    /// back at each redraw, as they did while paused.
    func test_a_resume_still_connecting_keeps_the_times_where_the_audio_stopped() {
        let appState = makeAppState()
        let pausedAt = Date().addingTimeInterval(-300)
        play(eldad(song: "A", startedAgo: 200), in: appState,
             followsHls: false, pausedAt: pausedAt)

        appState.isPlaybackPaused = false
        appState.audioStoppedAtProvider = { pausedAt }

        XCTAssertEqual(appState.heardClock, .stopped(at: pausedAt))
    }

    /// Waits until the refresh a tune-in asks for has run, answered or not.
    private func tuneInRefreshed(
        _ appState: AppState,
        after count: Int
    ) async -> Bool {
        await eventually {
            self.paths(after: count).contains("/api/v1/stations")
                && !appState.isLoading
        }
    }

    /// The engine plays the current station's HLS stream, heard `heardLag`
    /// seconds behind live.
    private func playsHls(in appState: AppState, heardLag: TimeInterval) {
        appState.followsHlsAudioProvider = { true }
        appState.hlsHeardDateProvider = { Date().addingTimeInterval(-heardLag) }
        appState.hlsPlaybackTimestampProvider = {
            roundedTimestamp(at: Date().addingTimeInterval(-heardLag))
        }
    }

    // MARK: - Previous / next show the song at once (round 6)

    /// The user saw next show the station's name, then its song: the
    /// station's history came only after the tune-in. The live songs seen
    /// meanwhile already tell which one its audio is in.
    func test_a_tune_in_shows_the_song_the_live_payloads_recorded() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "P", startedAgo: 300)])
        await appState.loadStations()
        try StubAPIProtocol.serveMetadata([live(song: "L", startedAgo: 60)])
        await appState.enqueueSync(.periodic)
        let station = try XCTUnwrap(appState.stations.first)

        appState.selectStation(station)

        XCTAssertEqual(appState.currentStation?.songTitle, "P")
        XCTAssertEqual(appState.currentStation?.nowPlaying?.song?.id, 1,
                       "a like of it names the song")
    }

    /// Check, round 6: a like of the song a tune-in took from the history
    /// went out without its id, as a review of the station.
    func test_a_tune_in_song_from_the_history_keeps_its_api_id() async throws {
        let appState = makeAppState()
        let station = eldad(song: "L", startedAgo: 60)
        appState.songHistory.seed([
            SongEntry(title: "L", artist: "", songId: 2,
                      timestamp: Date().addingTimeInterval(-60)),
            SongEntry(title: "P", artist: "", songId: 41636,
                      timestamp: Date().addingTimeInterval(-300)),
        ], for: "eldad")
        try StubAPIProtocol.serve([station])
        play(station, in: appState)

        await appState.loadStations()

        XCTAssertEqual(appState.currentStation?.songTitle, "P")
        XCTAssertEqual(appState.currentStation?.nowPlaying?.song?.id, 41636)
    }

    /// A payload that only brings the song's id is shown: the like buttons
    /// name the song by it.
    func test_a_payload_that_brings_the_song_id_is_shown() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([
            radio(id: stationId, slug: "eldad", song: "A", songId: 0,
                  startedAgo: 200),
        ])
        await appState.loadStations()
        // Nothing else changes: the same song, listeners and uptime.
        try StubAPIProtocol.serveMetadata([
            live(song: "A", songId: 9, listeners: 10, startedAgo: 200),
        ])

        await appState.enqueueSync(.periodic)

        XCTAssertEqual(appState.stations.first?.nowPlaying?.song?.id, 9)
    }

    func test_a_tune_in_loads_the_histories_of_the_stations_beside_it() async throws {
        let appState = makeAppState()
        let stations = ["a", "b", "c"].enumerated().map {
            radio(id: $0.offset + 1, slug: $0.element, song: "S",
                  startedAgo: 60)
        }
        try StubAPIProtocol.serve(stations)
        await appState.loadStations()
        let before = StubAPIProtocol.requestedURLs.count

        appState.selectStation(stations[1], browsingOrder: [1, 2, 3])

        let all = await historyFetched(3, after: before)
        let slugs = StubAPIProtocol.requestedURLs.dropFirst(before)
            .filter { $0.path == Self.historyPath }
            .compactMap { query("station_slug", of: $0) }
        XCTAssertTrue(all, "\(slugs)")
        XCTAssertEqual(slugs.first, "b", "the station tuned in first")
        XCTAssertEqual(Set(slugs), ["a", "b", "c"])
    }

    /// Check, round 7: the first tune-in after launch, to a station whose
    /// live song began within the minutes its audio is behind, showed the
    /// station's name, then the song before it once the history came. A
    /// focused card loads its history first, and the tune-in shows that
    /// song at once.
    func test_a_tune_in_after_its_card_had_focus_shows_the_song_at_once() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "L", startedAgo: 60)])
        try StubAPIProtocol.serveHistory([
            ["timestamp": stamp(ago: 300), "song": ["id": 41636, "name": "P"]],
            ["timestamp": stamp(ago: 60), "song": ["id": 1, "name": "L"]],
        ])
        await appState.loadStations()
        let listed = try XCTUnwrap(appState.stations.first)

        appState.stationCardFocused(listed)
        let seeded = await eventually {
            appState.songHistory.hasCurrentHistory(for: "eldad")
        }
        appState.selectStation(listed)

        XCTAssertTrue(seeded)
        XCTAssertEqual(appState.currentStation?.songTitle, "P")
        XCTAssertFalse(appState.isAwaitingSong)
    }

    /// Review, round 8: with the history out of reach, every focus of the
    /// card asked for it again.
    func test_a_focused_card_whose_history_failed_does_not_ask_again() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "L", startedAgo: 60)])
        await appState.loadStations()
        let listed = try XCTUnwrap(appState.stations.first)
        let before = StubAPIProtocol.requestedURLs.count
        appState.stationCardFocused(listed)
        let asked = await historyFetched(1, after: before)
        await letQueuedWorkRun()

        appState.stationCardFocused(listed)
        appState.stationCardFocused(listed)
        await letQueuedWorkRun()

        XCTAssertTrue(asked)
        XCTAssertEqual(
            paths(after: before).filter { $0 == Self.historyPath }.count, 1
        )
    }

    /// Review, round 9: one history request lost to a network drop left
    /// the station without its focus preload for the whole session.
    func test_a_history_out_of_reach_is_asked_again_once_the_api_answers() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([eldad(song: "L", startedAgo: 60)])
        await appState.loadStations()
        let listed = try XCTUnwrap(appState.stations.first)
        StubAPIProtocol.setUnreachable(Self.historyPath)
        let before = StubAPIProtocol.requestedURLs.count
        appState.stationCardFocused(listed)
        let asked = await historyFetched(1, after: before)
        await letQueuedWorkRun()
        appState.stationCardFocused(listed)
        await letQueuedWorkRun()
        XCTAssertTrue(asked)
        XCTAssertEqual(
            paths(after: before).filter { $0 == Self.historyPath }.count, 1,
            "not while it is out of reach"
        )

        StubAPIProtocol.setUnreachable(Self.historyPath, false)
        await appState.enqueueSync(.periodic)
        appState.stationCardFocused(listed)

        let again = await historyFetched(2, after: before)
        XCTAssertTrue(again)
    }

    /// Check, round 9: in a grid of two, next and previous are the same
    /// station, whose history a tune-in asked for twice.
    func test_a_neighbour_on_both_sides_has_its_history_asked_for_once() async throws {
        let appState = makeAppState()
        let stations = ["a", "b"].enumerated().map {
            radio(id: $0.offset + 1, slug: $0.element, song: "S",
                  startedAgo: 60)
        }
        try StubAPIProtocol.serve(stations)
        await appState.loadStations()
        let before = StubAPIProtocol.requestedURLs.count

        appState.selectStation(stations[0], browsingOrder: [1, 2])

        let both = await historyFetched(2, after: before)
        await letQueuedWorkRun()
        let slugs = StubAPIProtocol.requestedURLs.dropFirst(before)
            .filter { $0.path == Self.historyPath }
            .compactMap { query("station_slug", of: $0) }
        XCTAssertTrue(both, "\(slugs)")
        XCTAssertEqual(slugs, ["a", "b"])
    }

    /// A tune-in that already knows its song asks for nothing: the live
    /// song began before the audio's moment, or the station is heard live.
    func test_a_focused_card_whose_song_is_known_asks_for_nothing() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([
            eldad(song: "P", startedAgo: 600),
            radio(id: 2, slug: "tv", song: "M", startedAgo: 60,
                  stationType: "tv"),
        ])
        await appState.loadStations()
        let before = StubAPIProtocol.requestedURLs.count

        appState.stations.forEach(appState.stationCardFocused)

        await letQueuedWorkRun()
        let history = StubAPIProtocol.requestedURLs.dropFirst(before)
            .filter { $0.path == Self.historyPath }
        XCTAssertEqual(history, [])
    }

    /// TV and playlist stations show no songs: their histories are not
    /// fetched for previous / next.
    func test_only_the_radio_stations_beside_it_have_their_histories_loaded() async throws {
        let appState = makeAppState()
        let stations = [
            radio(id: 1, slug: "a", song: "S", startedAgo: 60,
                  stationType: "tv"),
            radio(id: 2, slug: "b", song: "S", startedAgo: 60),
            radio(id: 3, slug: "c", song: "S", startedAgo: 60),
        ]
        try StubAPIProtocol.serve(stations)
        await appState.loadStations()
        let before = StubAPIProtocol.requestedURLs.count

        appState.selectStation(stations[1], browsingOrder: [1, 2, 3])

        let both = await historyFetched(2, after: before)
        await letQueuedWorkRun()
        let slugs = StubAPIProtocol.requestedURLs.dropFirst(before)
            .filter { $0.path == Self.historyPath }
            .compactMap { query("station_slug", of: $0) }
        XCTAssertTrue(both, "\(slugs)")
        XCTAssertEqual(Set(slugs), ["b", "c"])
    }

    // MARK: - Direct streams and stale songs (round 6)

    /// A direct stream is heard live and its song changes come only with
    /// the poll: every 15 s while it plays, every minute otherwise.
    func test_the_poll_runs_every_15_s_while_a_direct_stream_plays() {
        XCTAssertTrue(AppState.isPeriodicSyncDue(afterWakes: 1, playingDirectStream: true))
        XCTAssertFalse(AppState.isPeriodicSyncDue(afterWakes: 3, playingDirectStream: false))
        XCTAssertTrue(AppState.isPeriodicSyncDue(afterWakes: 4, playingDirectStream: false))
    }

    /// The faster poll is for a radio station's direct stream while it
    /// plays: not while HLS plays, while paused, or for TV.
    func test_the_faster_poll_is_for_a_playing_direct_stream() {
        let appState = makeAppState()
        var isPlaying = true
        var followsHls = false
        appState.isPlayingProvider = { isPlaying }
        appState.followsHlsAudioProvider = { followsHls }
        appState.currentStation = eldad(song: "A", startedAgo: 60)
        XCTAssertTrue(appState.isPlayingDirectStream)

        followsHls = true
        XCTAssertFalse(appState.isPlayingDirectStream, "HLS")

        followsHls = false
        isPlaying = false
        XCTAssertFalse(appState.isPlayingDirectStream, "paused")

        isPlaying = true
        appState.currentStation = radio(id: 9, slug: "tv", song: "",
                                        startedAgo: 60, stationType: "tv")
        XCTAssertFalse(appState.isPlayingDirectStream, "TV")
    }

    /// RVE Oradea Muzică kept its last song, 10.7 hours old, as playing.
    func test_a_now_playing_hours_old_is_no_song() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([
            eldad(song: "Astept la usa mea", startedAgo: 10.7 * 3600),
        ])

        await appState.loadStations()

        XCTAssertEqual(appState.stations.first?.songTitle, "")
    }

    /// RVE Sibiu showed Durch die Bibel, set 181 days before, as its song.
    func test_a_now_playing_months_old_is_no_song() async throws {
        let appState = makeAppState()
        try StubAPIProtocol.serve([
            eldad(song: "Durch die Bibel", startedAgo: 181 * 24 * 3600),
        ])

        await appState.loadStations()

        let station = try XCTUnwrap(appState.stations.first)
        XCTAssertNil(station.nowPlaying, "its picture included")
        XCTAssertEqual(station.songTitle, "")
    }
}
