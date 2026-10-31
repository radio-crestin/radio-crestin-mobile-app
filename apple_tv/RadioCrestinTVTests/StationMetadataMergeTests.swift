import XCTest
@testable import RadioCrestinTV

/// Which metadata payload may set a station's song (E10b). The live
/// payload and the one aligned with the HLS audio disagree for half a
/// minute after every song change; the playing HLS station shows the
/// newest song its audio has reached, whoever brought it.
final class StationMetadataMergeTests: XCTestCase {

    /// Song starts on the broadcast timeline: A, then B 180 s later.
    private let startA = Date(timeIntervalSince1970: 1_793_395_600)
    private lazy var startB = startA.addingTimeInterval(180)

    /// The API's timestamp format, with microseconds.
    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func nowPlaying(_ song: String, start: Date) -> NowPlaying {
        NowPlaying(
            id: 1,
            timestamp: stamp(start),
            song: Song(id: song.count, name: song, thumbnailUrl: nil,
                       artist: nil)
        )
    }

    private func station(song: String, start: Date, listeners: Int) -> Station {
        Station(
            id: 7,
            slug: "eldad",
            title: "Eldad",
            order: 0,
            thumbnailUrl: nil,
            totalListeners: listeners,
            stationStreams: [
                StationStream(order: 0, type: "HLS",
                              streamUrl: "https://x/eldad"),
            ],
            uptime: Uptime(isUp: true, timestamp: nil),
            nowPlaying: nowPlaying(song, start: start),
            reviewsStats: nil,
            stationType: nil,
            playlistItems: nil,
            hlsDvrStreamUrl: nil
        )
    }

    private func payload(
        song: String,
        start: Date,
        listeners: Int,
        isUp: Bool = true
    ) -> StationMetadata {
        StationMetadata(
            id: 7,
            uptime: Uptime(isUp: isUp, timestamp: nil),
            now_playing: NowPlayingMetadata(
                timestamp: stamp(start),
                listeners: listeners,
                song: Song(id: song.count, name: song,
                           thumbnailUrl: nil, artist: nil)
            )
        )
    }

    /// The song on the live timeline, a song change ahead of the audio.
    private lazy var liveB = payload(song: "B", start: startB, listeners: 30)
    /// The song the HLS listener hears; its station looked down then.
    private lazy var alignedA = payload(
        song: "A", start: startA, listeners: 20, isUp: false
    )

    /// The playing HLS station's clock, `seconds` after B started live.
    private func audio(_ seconds: TimeInterval) -> SongClock {
        .audio(heardAt: startB.addingTimeInterval(seconds))
    }

    // MARK: - Live clock (every station that is not playing HLS)

    func test_live_clock_ignores_an_audio_aligned_payload() {
        let base = station(song: "A", start: startA, listeners: 10)
        let merged = StationMetadataMerge.merged(
            base, live: nil, offset: alignedA, clock: .live
        )
        XCTAssertEqual(merged, base)
    }

    func test_live_clock_takes_song_and_listeners_from_the_live_payload() {
        let merged = StationMetadataMerge.merged(
            station(song: "A", start: startA, listeners: 10),
            live: liveB, offset: alignedA, clock: .live
        )
        XCTAssertEqual(merged.songTitle, "B")
        XCTAssertEqual(merged.totalListeners, 30)
    }

    // MARK: - Audio clock (the playing HLS station)

    /// Review, low: tuning in 10 s after B started live, while the audio
    /// (18–30 s behind) is still in A. Taking B made the title read B, A.
    func test_a_live_song_the_audio_has_not_reached_is_not_shown() {
        let shownA = nowPlaying("A", start: startA)
        let merged = StationMetadataMerge.merged(
            station(song: "B", start: startB, listeners: 10),
            shown: shownA, live: liveB, offset: nil, clock: audio(-20)
        )
        XCTAssertEqual(merged.songTitle, "A")
        XCTAssertEqual(merged.totalListeners, 30)
    }

    /// Review, high: after an aligned A, the audio passes B's start. The
    /// live payload carrying B must move the title on; ignoring it left
    /// the title a song behind until the next announcement.
    func test_a_live_song_the_audio_has_reached_is_shown() {
        let shownA = nowPlaying("A", start: startA)
        let merged = StationMetadataMerge.merged(
            station(song: "A", start: startA, listeners: 10),
            shown: shownA, live: liveB, offset: nil, clock: audio(5)
        )
        XCTAssertEqual(merged.songTitle, "B")
        XCTAssertEqual(merged.nowPlaying?.timestamp, stamp(startB))
    }

    func test_an_aligned_payload_sets_the_song_but_not_the_listeners() {
        let merged = StationMetadataMerge.merged(
            station(song: "B", start: startB, listeners: 10),
            shown: nowPlaying("B", start: startB),
            live: nil, offset: alignedA, clock: audio(-20)
        )
        XCTAssertEqual(merged.songTitle, "A")
        XCTAssertEqual(merged.nowPlaying?.timestamp, stamp(startA))
        XCTAssertEqual(merged.totalListeners, 10)
    }

    /// The aligned fetch asks for the audio's moment rounded down to 10 s,
    /// so just after a change it can still answer the song before it.
    func test_an_older_aligned_payload_does_not_take_back_a_reached_song() {
        let merged = StationMetadataMerge.merged(
            station(song: "B", start: startB, listeners: 10),
            shown: nowPlaying("B", start: startB),
            live: nil, offset: alignedA, clock: audio(4)
        )
        XCTAssertEqual(merged.songTitle, "B")
    }

    /// Back on HLS after the live MP3: the audio is behind the song shown.
    func test_a_shown_song_ahead_of_the_audio_gives_way_to_the_aligned_one() {
        let merged = StationMetadataMerge.merged(
            station(song: "B", start: startB, listeners: 10),
            shown: nowPlaying("B", start: startB),
            live: liveB, offset: alignedA, clock: audio(-20)
        )
        XCTAssertEqual(merged.songTitle, "A")
    }

    /// Review C3: a tune-in 2 minutes behind live showed the catalog's
    /// live song until the aligned payload came, and recorded it as heard.
    func test_with_no_song_known_to_be_reached_none_is_shown() {
        let merged = StationMetadataMerge.merged(
            station(song: "B", start: startB, listeners: 10),
            shown: nowPlaying("B", start: startB),
            live: liveB, offset: nil, clock: audio(-20)
        )
        XCTAssertEqual(merged.songTitle, "")
        XCTAssertNil(merged.nowPlaying)
        XCTAssertEqual(merged.totalListeners, 30)
    }

    /// Nothing says it is ahead of the audio: it stays the best guess.
    func test_a_song_without_a_start_stays_until_one_is_heard() {
        let undated = NowPlaying(
            id: 1, timestamp: nil,
            song: Song(id: 3, name: "C", thumbnailUrl: nil, artist: nil)
        )
        var base = station(song: "B", start: startB, listeners: 10)
        base.nowPlaying = undated
        let merged = StationMetadataMerge.merged(
            base, shown: undated, live: liveB, offset: nil, clock: audio(-20)
        )
        XCTAssertEqual(merged.songTitle, "C")
    }

    /// The history knows the play the audio is in before an aligned
    /// payload says so.
    func test_the_play_the_history_puts_the_audio_in_is_shown() {
        let merged = StationMetadataMerge.merged(
            station(song: "B", start: startB, listeners: 10),
            shown: nowPlaying("B", start: startB),
            live: liveB, offset: nil,
            history: nowPlaying("A", start: startA),
            clock: audio(-20)
        )
        XCTAssertEqual(merged.songTitle, "A")
        XCTAssertEqual(merged.nowPlaying?.timestamp, stamp(startA))
    }

    /// The history can lag the payloads: a newer song they show the audio
    /// has reached stays.
    func test_an_older_history_play_does_not_take_back_a_reached_song() {
        let merged = StationMetadataMerge.merged(
            station(song: "B", start: startB, listeners: 10),
            shown: nowPlaying("B", start: startB),
            live: liveB, offset: nil,
            history: nowPlaying("A", start: startA),
            clock: audio(5)
        )
        XCTAssertEqual(merged.songTitle, "B")
    }

    func test_listeners_and_uptime_come_from_the_live_payload() {
        let merged = StationMetadataMerge.merged(
            station(song: "A", start: startA, listeners: 10),
            shown: nowPlaying("A", start: startA),
            live: liveB, offset: alignedA, clock: audio(-20)
        )
        XCTAssertEqual(merged.songTitle, "A")
        XCTAssertEqual(merged.totalListeners, 30)
        XCTAssertTrue(merged.isUp)
    }

    /// E10b: live and aligned payloads alternate for the playing station
    /// while the audio is still in A; the title must not flip.
    func test_alternating_payloads_do_not_flip_the_title() {
        var shown = station(song: "A", start: startA, listeners: 10)
        var titles: [String] = []
        for index in 0..<6 {
            let isLive = index.isMultiple(of: 2)
            shown = StationMetadataMerge.merged(
                shown,
                shown: shown.nowPlaying,
                live: isLive ? liveB : nil,
                offset: isLive ? nil : alignedA,
                clock: audio(-15 + Double(index))
            )
            titles.append(shown.songTitle)
        }
        XCTAssertEqual(titles, Array(repeating: "A", count: 6))
    }

    /// The title follows the audio through a change, whatever the order
    /// the payloads come in: A until the audio reaches B, then B for good.
    func test_the_title_follows_the_audio_through_a_song_change() {
        var shown = station(song: "A", start: startA, listeners: 10)
        let steps: [(TimeInterval, StationMetadata?, StationMetadata?)] = [
            (-18, liveB, nil),
            (-12, nil, alignedA),
            (2, nil, alignedA),
            (3, liveB, nil),
            (8, nil, alignedA),
            (14, liveB, alignedA),
        ]
        var titles: [String] = []
        for (seconds, live, offset) in steps {
            shown = StationMetadataMerge.merged(
                shown, shown: shown.nowPlaying,
                live: live, offset: offset, clock: audio(seconds)
            )
            titles.append(shown.songTitle)
        }
        XCTAssertEqual(titles, ["A", "A", "A", "B", "B", "B"])
    }

    // MARK: - Fetch timing

    /// The audio-aligned fetch rounds the playhead down to 10 s; it asks
    /// about a moment past a song change only from the next 10 s mark.
    func test_the_first_fetch_moment_after_a_change_is_the_next_10s_mark() {
        let change = Date(timeIntervalSince1970: 1_793_395_784.04)
        XCTAssertEqual(
            nextRoundedMoment(after: change).timeIntervalSince1970,
            1_793_395_790
        )
        let onTheMark = Date(timeIntervalSince1970: 1_793_395_780)
        XCTAssertEqual(
            nextRoundedMoment(after: onTheMark).timeIntervalSince1970,
            1_793_395_790
        )
        XCTAssertGreaterThan(
            roundedTimestamp(at: nextRoundedMoment(after: change)),
            Int(change.timeIntervalSince1970)
        )
    }
}
