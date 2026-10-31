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
        // A direct stream shows the live song.
        store.record(songTitle: "B", artist: "x", startedAt: startB, for: "s")
        XCTAssertEqual(titles(store), ["B", "A"])

        // The HLS audio is still on A: B has not been heard yet.
        store.record(songTitle: "A", artist: "x", startedAt: startA,
                     heardAt: startB - 20, for: "s")
        XCTAssertEqual(titles(store), ["A"])

        // The audio reaches B.
        store.record(songTitle: "B", artist: "x", startedAt: startB,
                     heardAt: startB + 5, for: "s")
        XCTAssertEqual(titles(store), ["B", "A"])

        // Live again (fallen back to MP3): nothing is hidden.
        store.record(songTitle: "C", artist: "x", startedAt: startC, for: "s")
        XCTAssertEqual(titles(store), ["C", "B", "A"])
    }

    /// Review C3: a tune-in shows no song until one is known to be heard,
    /// and the history must not list the live one either.
    func test_with_no_song_shown_plays_after_the_audio_stay_hidden() {
        let store = SongHistoryStore()
        store.seed([
            SongEntry(title: "B", artist: "x", timestamp: startB),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ], for: "s")

        store.record(songTitle: "", artist: "", heardAt: startB - 20,
                     for: "s")

        XCTAssertEqual(titles(store), ["A"])
    }

    func test_a_seed_after_an_aligned_record_still_hides_unheard_plays() {
        let store = SongHistoryStore()
        store.record(songTitle: "A", artist: "x", startedAt: startA,
                     heardAt: startA + 30, for: "s")
        store.seed([
            SongEntry(title: "B", artist: "x", timestamp: startB),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ], for: "s")

        XCTAssertEqual(titles(store), ["A"])
        XCTAssertTrue(store.hasCurrentHistory(for: "s"))
    }

    func test_the_api_history_is_current_once_in_hidden_plays_and_all() {
        let store = SongHistoryStore()
        XCTAssertFalse(store.hasCurrentHistory(for: "s"))

        store.record(songTitle: "A", artist: "x", startedAt: startA,
                     heardAt: startA + 30, for: "s")
        store.seed([SongEntry(title: "B", artist: "x", timestamp: startB)],
                   for: "s")

        XCTAssertTrue(store.hasCurrentHistory(for: "s"))
        XCTAssertFalse(store.hasCurrentHistory(for: "other"))
    }

    /// Final check, round 2: the song a tune-in shows was recorded before
    /// the fetch was decided, counted as history, and "Melodii recente"
    /// stayed empty all session.
    func test_the_song_on_screen_is_no_api_history() {
        let store = SongHistoryStore()

        store.record(songTitle: "A", artist: "x", startedAt: startA,
                     heardAt: startA + 30, for: "s")

        XCTAssertFalse(store.hasCurrentHistory(for: "s"))
    }

    func test_an_empty_api_history_is_current_too() {
        let store = SongHistoryStore()

        store.seed([], for: "s")

        XCTAssertTrue(store.hasCurrentHistory(for: "s"))
        XCTAssertEqual(titles(store), [])
    }

    /// Review, round 3: a station opened again hours later kept the plays
    /// of its last visit under the song now on, with the gap between.
    func test_an_api_history_goes_stale() {
        let store = SongHistoryStore()
        let loaded = Date()

        store.seed([], for: "s", at: loaded)

        XCTAssertTrue(store.hasCurrentHistory(for: "s", at: loaded + 9 * 60))
        XCTAssertFalse(store.hasCurrentHistory(for: "s", at: loaded + 10 * 60))
    }

    // MARK: - Blips in a station's metadata

    /// Final check, round 3: Radio Gosen sent Maranatha, 2 s later the
    /// song before it and 13 s later Maranatha again, and the list showed
    /// Maranatha a second time under the title.
    func test_a_blip_between_two_plays_of_one_song_makes_one_play() {
        let maranatha = startC - 60
        let store = SongHistoryStore()
        store.seed([
            SongEntry(title: "Maranatha", artist: "x", timestamp: maranatha + 15),
            SongEntry(title: "Miezul Nopții", artist: "x", timestamp: maranatha + 2),
            SongEntry(title: "Maranatha", artist: "x", timestamp: maranatha),
            SongEntry(title: "Miezul Nopții", artist: "x", timestamp: startA),
        ], for: "s")

        XCTAssertEqual(titles(store), ["Maranatha", "Miezul Nopții"])
        XCTAssertEqual(store.entries(for: "s").first?.timestamp, maranatha)
    }

    func test_a_whole_play_between_two_plays_of_one_song_stays() {
        let store = SongHistoryStore()
        store.seed([
            SongEntry(title: "A", artist: "x", timestamp: startC),
            SongEntry(title: "B", artist: "x", timestamp: startC - 30),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ], for: "s")

        XCTAssertEqual(titles(store), ["A", "B", "A"])
    }

    func test_a_blip_recorded_from_the_screen_makes_one_play_too() {
        let store = SongHistoryStore()
        store.record(songTitle: "A", artist: "x", startedAt: startA, for: "s")
        store.record(songTitle: "B", artist: "x", startedAt: startB, for: "s")

        store.record(songTitle: "A", artist: "x", startedAt: startB + 10,
                     for: "s")

        XCTAssertEqual(titles(store), ["A"])
        XCTAssertEqual(store.entries(for: "s").first?.timestamp, startA)
    }

    // MARK: - The play the audio is in

    func test_the_play_heard_is_the_newest_that_started_by_then() {
        let timeline = [
            SongEntry(title: "C", artist: "x", timestamp: startC),
            SongEntry(title: "B", artist: "x", timestamp: startB),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ]

        XCTAssertEqual(
            SongTimeline.play(heardAt: startB + 10, in: timeline)?.title, "B"
        )
        XCTAssertEqual(
            SongTimeline.play(heardAt: startB - 10, in: timeline)?.title, "A"
        )
        XCTAssertNil(SongTimeline.play(heardAt: startA - 10, in: timeline))
    }

    /// A history that ends before the moment may miss plays since its
    /// newest one: its newest says nothing about what is heard.
    func test_a_history_that_ends_before_the_moment_names_no_play() {
        let store = SongHistoryStore()
        store.seed([
            SongEntry(title: "B", artist: "x", timestamp: startB),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ], for: "s")

        XCTAssertEqual(store.play(heardAt: startB - 10, for: "s")?.title, "A")
        XCTAssertNil(store.play(heardAt: startB + 10, for: "s"))
        XCTAssertNil(store.play(heardAt: startB - 10, for: "other"))
    }

    /// Final check, round 2: tuned in 128 s after a song change, the
    /// estimate (132 s behind live) named the song before it, while the
    /// audio, 123 s behind, was past the change: the title showed the old
    /// song for 0.7 s, then the one heard.
    func test_a_song_change_within_the_uncertainty_names_no_play() {
        let timeline = [
            SongEntry(title: "C", artist: "x", timestamp: startC),
            SongEntry(title: "B", artist: "x", timestamp: startB),
            SongEntry(title: "A", artist: "x", timestamp: startA),
        ]

        XCTAssertNil(SongTimeline.play(
            heardAt: startB - 4, uncertainty: 18, in: timeline
        ))
        XCTAssertEqual(SongTimeline.play(
            heardAt: startB - 20, uncertainty: 18, in: timeline
        )?.title, "A")
        XCTAssertEqual(SongTimeline.play(
            heardAt: startB, uncertainty: 18, in: timeline
        )?.title, "B")
        // B lasts 30 s: C may have started by the end.
        XCTAssertNil(SongTimeline.play(
            heardAt: startB + 15, uncertainty: 18, in: timeline
        ))
    }

    // MARK: - "Melodii recente" under the song shown

    /// Review C5: the first row repeated the song shown above it.
    func test_the_list_leaves_out_the_song_shown_above_it() {
        let entries = [
            SongEntry(title: "Har", artist: "Cor", timestamp: startB),
            SongEntry(title: "Psalm", artist: "Cor", timestamp: startA),
        ]

        XCTAssertEqual(
            SongTimeline.before(shownTitle: "har ", artist: "COR", in: entries)
                .map(\.title),
            ["Psalm"]
        )
        XCTAssertEqual(
            SongTimeline.before(shownTitle: "Har", artist: "Alt cor", in: entries)
                .map(\.title),
            ["Har", "Psalm"]
        )
        XCTAssertEqual(
            SongTimeline.before(shownTitle: "", artist: "", in: entries).count,
            2
        )
    }

    /// The same song further down is an earlier play of it, and stays.
    func test_only_the_newest_entry_can_be_the_song_shown() {
        let entries = [
            SongEntry(title: "Psalm", artist: "Cor", timestamp: startC),
            SongEntry(title: "Har", artist: "Cor", timestamp: startB),
            SongEntry(title: "Psalm", artist: "Cor", timestamp: startA),
        ]

        XCTAssertEqual(
            SongTimeline.before(shownTitle: "Har", artist: "Cor", in: entries)
                .map(\.title),
            ["Psalm", "Har", "Psalm"]
        )
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

    /// A play keeps the API's id of its song from whichever report has
    /// it: a like of it names the song (`NowPlaying(play:)`).
    func test_a_play_keeps_the_song_id_of_any_report() {
        let store = SongHistoryStore()
        store.record(songTitle: "B", artist: "x", startedAt: startB, for: "s")
        store.record(songTitle: "B", artist: "x", songId: 41636,
                     startedAt: startC, for: "s")
        XCTAssertEqual(store.entries(for: "s").first?.songId, 41636)
        XCTAssertEqual(store.entries(for: "s").first?.timestamp, startB)

        store.seed([
            SongEntry(title: "B", artist: "x", songId: 41636,
                      timestamp: startB),
            SongEntry(title: "A", artist: "x", songId: 7, timestamp: startA),
        ], for: "s")
        XCTAssertEqual(store.entries(for: "s").map(\.songId), [41636, 7])
        XCTAssertEqual(
            store.play(heardAt: startA.addingTimeInterval(10), for: "s")?.songId,
            7
        )
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
    /// timestamp must not date the row ("acum 180z"). One whose metadata
    /// stopped kept its last song as playing 10.7 hours on.
    func test_a_start_older_than_six_hours_is_no_song() {
        let seen = startC
        XCTAssertEqual(
            SongTimestamp.songStart(seen.addingTimeInterval(-5 * 3600),
                                    seenAt: seen),
            seen.addingTimeInterval(-5 * 3600)
        )
        XCTAssertNil(SongTimestamp.songStart(
            seen.addingTimeInterval(-7 * 3600), seenAt: seen
        ))
        XCTAssertNil(SongTimestamp.songStart(
            seen.addingTimeInterval(-10.7 * 3600), seenAt: seen
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
