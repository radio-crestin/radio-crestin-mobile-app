import Combine
import XCTest
@testable import RadioCrestinTV

/// "Melodii recente" as plays keyed by their start time: the API history,
/// the live song and the audio-aligned song of one play make one row
/// (E10a), and an HLS listener does not see plays the audio has not
/// reached yet (E10b).
@MainActor
final class SongTimelineTests: XCTestCase {

    /// Start times of three plays, oldest first. Fixed instants keep the
    /// tests independent of the clock.
    private let startA = Date(timeIntervalSince1970: 1_793_395_600)
    private let startB = Date(timeIntervalSince1970: 1_793_395_970)
    private let startC = Date(timeIntervalSince1970: 1_793_396_000)

    private func titles(_ store: SongHistoryStore) -> [String] {
        store.entries(for: "s").map(\.title)
    }

    // MARK: - One row per play (E10a)

    func test_a_live_record_and_the_api_history_of_one_play_make_one_row() {
        let store = SongHistoryStore()
        store.record(songTitle: "B", artist: "x", startedAt: startB, for: "s")
        store.seed([
            SongEntry(title: "B", artist: "x", timestamp: startB,
                      thumbnailUrl: "https://img/b"),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ], for: "s")

        XCTAssertEqual(titles(store), ["B", "A"])
        XCTAssertEqual(store.entries(for: "s").first?.timestamp, startB)
        XCTAssertEqual(
            store.entries(for: "s").first?.thumbnailUrl, "https://img/b"
        )
    }

    func test_a_record_after_the_seed_fills_in_the_artwork() {
        let store = SongHistoryStore()
        store.seed([
            SongEntry(title: "B", artist: "x", timestamp: startB),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ], for: "s")
        store.record(songTitle: "B", artist: "x", startedAt: startB,
                     thumbnailUrl: "https://img/b", for: "s")

        XCTAssertEqual(titles(store), ["B", "A"])
        XCTAssertEqual(
            store.entries(for: "s").first?.thumbnailUrl, "https://img/b"
        )
    }

    func test_a_song_reported_again_later_keeps_its_first_start() {
        let store = SongHistoryStore()
        store.record(songTitle: "B", artist: "x", startedAt: startB, for: "s")
        store.record(songTitle: "B", artist: "x", startedAt: startC, for: "s")

        XCTAssertEqual(titles(store), ["B"])
        XCTAssertEqual(store.entries(for: "s").first?.timestamp, startB)
    }

    func test_a_song_that_really_played_again_keeps_its_own_row() {
        let store = SongHistoryStore()
        store.record(songTitle: "A", artist: "x", startedAt: startA, for: "s")
        store.record(songTitle: "B", artist: "x", startedAt: startB, for: "s")
        store.record(songTitle: "A", artist: "x", startedAt: startC, for: "s")

        XCTAssertEqual(titles(store), ["A", "B", "A"])
    }

    func test_a_late_report_of_an_older_play_goes_into_start_order() {
        let store = SongHistoryStore()
        store.record(songTitle: "C", artist: "x", startedAt: startC, for: "s")
        store.record(songTitle: "A", artist: "x", startedAt: startA, for: "s")

        XCTAssertEqual(titles(store), ["C", "A"])
    }

    // MARK: - Plays ahead of an HLS listener (E10b)

    func test_plays_ahead_of_the_audio_stay_hidden_until_heard() {
        let store = SongHistoryStore()
        store.seed([
            SongEntry(title: "B", artist: "x", timestamp: startB),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ], for: "s")
        // Before the first audio-aligned payload the live song shows.
        store.record(songTitle: "B", artist: "x", startedAt: startB, for: "s")
        XCTAssertEqual(titles(store), ["B", "A"])

        // The audio is still on A: B has not been heard yet.
        store.record(songTitle: "A", artist: "x", startedAt: startA,
                     isAudioAligned: true, for: "s")
        XCTAssertEqual(titles(store), ["A"])

        // The audio reaches B.
        store.record(songTitle: "B", artist: "x", startedAt: startB,
                     isAudioAligned: true, for: "s")
        XCTAssertEqual(titles(store), ["B", "A"])

        // Live again (paused, or fallen back to MP3): nothing is hidden.
        store.record(songTitle: "C", artist: "x", startedAt: startC, for: "s")
        XCTAssertEqual(titles(store), ["C", "B", "A"])
    }

    func test_a_seed_after_an_aligned_record_still_hides_unheard_plays() {
        let store = SongHistoryStore()
        store.record(songTitle: "A", artist: "x", startedAt: startA,
                     isAudioAligned: true, for: "s")
        store.seed([
            SongEntry(title: "B", artist: "x", timestamp: startB),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ], for: "s")

        XCTAssertEqual(titles(store), ["A"])
        XCTAssertTrue(store.hasHistory(for: "s"))
    }

    func test_hidden_plays_count_as_history_so_it_is_not_fetched_again() {
        let store = SongHistoryStore()
        XCTAssertFalse(store.hasHistory(for: "s"))

        store.record(songTitle: "A", artist: "x", startedAt: startA,
                     isAudioAligned: true, for: "s")
        store.seed([SongEntry(title: "B", artist: "x", timestamp: startB)],
                   for: "s")

        XCTAssertTrue(store.hasHistory(for: "s"))
        XCTAssertFalse(store.hasHistory(for: "other"))
    }

    // MARK: - Redraws

    func test_recording_the_same_song_again_publishes_nothing() {
        let store = SongHistoryStore()
        var publishes = 0
        let subscription = store.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }

        for _ in 0..<3 {
            store.record(songTitle: "A", artist: "x", startedAt: startA,
                         thumbnailUrl: "https://img/a", for: "s")
        }

        XCTAssertEqual(publishes, 1)
    }

    // MARK: - SongTimeline

    func test_collapsing_keeps_the_earliest_start_and_the_first_artwork() {
        let collapsed = SongTimeline.collapsingRepeats([
            SongEntry(title: "B", artist: "x", timestamp: startC,
                      thumbnailUrl: "https://img/b"),
            SongEntry(title: "b", artist: "X", timestamp: startB),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ])

        XCTAssertEqual(collapsed.map(\.title), ["b", "A"])
        XCTAssertEqual(collapsed.first?.timestamp, startB)
        XCTAssertEqual(collapsed.first?.thumbnailUrl, "https://img/b")
    }

    func test_the_timeline_is_capped() {
        var timeline: [SongEntry] = []
        for index in 0..<(SongTimeline.capacity + 5) {
            timeline = SongTimeline.inserting(
                SongEntry(
                    title: "Song\(index)", artist: "x",
                    timestamp: startA.addingTimeInterval(Double(index))
                ),
                into: timeline
            )
        }

        XCTAssertEqual(timeline.count, SongTimeline.capacity)
        XCTAssertEqual(timeline.first?.title, "Song\(SongTimeline.capacity + 4)")
    }

    func test_audible_without_a_horizon_shows_every_play() {
        let plays = [
            SongEntry(title: "B", artist: "x", timestamp: startB),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ]
        XCTAssertEqual(
            SongTimeline.audible(plays, horizon: nil).map(\.title), ["B", "A"]
        )
        XCTAssertEqual(
            SongTimeline.audible(plays, horizon: startA).map(\.title), ["A"]
        )
    }

    // MARK: - Song start times

    func test_song_start_parses_microsecond_and_plain_timestamps() throws {
        let fractional = try XCTUnwrap(
            SongTimestamp.date(from: "2026-10-30T21:34:46.041615+00:00")
        )
        XCTAssertEqual(
            fractional.timeIntervalSince1970, 1_793_396_086.041, accuracy: 0.001
        )
        let plain = try XCTUnwrap(
            SongTimestamp.date(from: "2026-10-30T21:34:46+00:00")
        )
        XCTAssertEqual(plain.timeIntervalSince1970, 1_793_396_086)
        XCTAssertNil(SongTimestamp.date(from: "not a date"))
    }

    func test_a_station_without_a_song_timestamp_has_no_start() {
        let station = Station(
            id: 1, slug: "s", title: "S", order: 0, thumbnailUrl: nil,
            totalListeners: nil, stationStreams: [], uptime: nil,
            nowPlaying: NowPlaying(id: 1, timestamp: nil, song: nil),
            reviewsStats: nil, stationType: nil, playlistItems: nil,
            hlsDvrStreamUrl: nil
        )
        XCTAssertNil(station.songStartDate)
    }

    /// A station that reports no songs keeps one label for months; its
    /// timestamp must not date the row ("acum 180z").
    func test_a_start_older_than_a_day_is_a_fixed_label_not_a_song() {
        let seen = startC
        XCTAssertEqual(
            SongTimestamp.songStart(seen.addingTimeInterval(-23 * 3600),
                                    seenAt: seen),
            seen.addingTimeInterval(-23 * 3600)
        )
        XCTAssertNil(SongTimestamp.songStart(
            seen.addingTimeInterval(-25 * 3600), seenAt: seen
        ))
        XCTAssertNil(SongTimestamp.songStart(
            seen.addingTimeInterval(-180 * 86_400), seenAt: seen
        ))
    }

    func test_a_fixed_label_keeps_the_time_it_was_first_seen() {
        let store = SongHistoryStore()
        store.record(songTitle: "Numai la cruce", artist: "x", for: "s")
        let firstSeen = store.entries(for: "s").first?.timestamp
        store.record(songTitle: "Numai la cruce", artist: "x", for: "s")

        XCTAssertEqual(store.entries(for: "s").count, 1)
        XCTAssertEqual(store.entries(for: "s").first?.timestamp, firstSeen)
    }
}
