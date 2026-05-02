import XCTest
@testable import RadioCrestinTV

@MainActor
final class SongHistoryStoreTests: XCTestCase {

    func test_record_appends_first_entry_for_a_station() {
        let store = SongHistoryStore()
        store.record(songTitle: "Amazing Grace", artist: "Choir",
                     for: "radio-x")
        let entries = store.entries(for: "radio-x")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "Amazing Grace")
        XCTAssertEqual(entries.first?.artist, "Choir")
    }

    func test_record_dedupes_consecutive_same_song() {
        let store = SongHistoryStore()
        store.record(songTitle: "X", artist: "A", for: "s")
        store.record(songTitle: "X", artist: "A", for: "s")
        store.record(songTitle: "x", artist: "a", for: "s") // case-insensitive
        XCTAssertEqual(store.entries(for: "s").count, 1)
    }

    func test_record_appends_when_song_changes() {
        let store = SongHistoryStore()
        store.record(songTitle: "X", artist: "A", for: "s")
        store.record(songTitle: "Y", artist: "B", for: "s")
        let entries = store.entries(for: "s")
        XCTAssertEqual(entries.count, 2)
        // Newest-first ordering
        XCTAssertEqual(entries.first?.title, "Y")
        XCTAssertEqual(entries.last?.title, "X")
    }

    func test_record_trims_whitespace_and_skips_empty_titles() {
        let store = SongHistoryStore()
        store.record(songTitle: "   ", artist: "A", for: "s")
        XCTAssertTrue(store.entries(for: "s").isEmpty)

        store.record(songTitle: "  Hymn  ", artist: "A", for: "s")
        XCTAssertEqual(store.entries(for: "s").first?.title, "Hymn")
    }

    func test_record_caps_history_at_20_entries() {
        let store = SongHistoryStore()
        for i in 0..<25 {
            store.record(songTitle: "Song\(i)", artist: "A", for: "s")
        }
        XCTAssertEqual(store.entries(for: "s").count, 20)
        // Newest stays at the front.
        XCTAssertEqual(store.entries(for: "s").first?.title, "Song24")
    }

    func test_record_isolates_per_station() {
        let store = SongHistoryStore()
        store.record(songTitle: "A", artist: "x", for: "s1")
        store.record(songTitle: "B", artist: "y", for: "s2")
        XCTAssertEqual(store.entries(for: "s1").count, 1)
        XCTAssertEqual(store.entries(for: "s1").first?.title, "A")
        XCTAssertEqual(store.entries(for: "s2").first?.title, "B")
    }

    func test_seed_replaces_when_existing_is_empty() {
        let store = SongHistoryStore()
        let now = Date()
        let seeded = [
            SongEntry(title: "S2", artist: "A",
                      timestamp: now.addingTimeInterval(-10)),
            SongEntry(title: "S1", artist: "A",
                      timestamp: now.addingTimeInterval(-100)),
        ]
        store.seed(seeded, for: "s")
        XCTAssertEqual(store.entries(for: "s").map(\.title), ["S2", "S1"])
    }

    func test_seed_preserves_locally_recorded_entries_newer_than_seed_head() {
        let store = SongHistoryStore()
        // Record live first (so its timestamp is "now")
        store.record(songTitle: "Live", artist: "A", for: "s")

        // Seed with older API entries.
        let oldDate = Date().addingTimeInterval(-3600)
        let seeded = [
            SongEntry(title: "Older1", artist: "A", timestamp: oldDate),
            SongEntry(title: "Older2", artist: "A",
                      timestamp: oldDate.addingTimeInterval(-60)),
        ]
        store.seed(seeded, for: "s")

        // The locally-recorded "Live" entry is newer than seedHead → kept.
        let titles = store.entries(for: "s").map(\.title)
        XCTAssertEqual(titles, ["Live", "Older1", "Older2"])
    }

    func test_seed_with_empty_input_is_a_no_op() {
        let store = SongHistoryStore()
        store.record(songTitle: "X", artist: "A", for: "s")
        store.seed([], for: "s")
        XCTAssertEqual(store.entries(for: "s").count, 1)
    }

    func test_seed_caps_at_20_entries() {
        let store = SongHistoryStore()
        let now = Date()
        let entries = (0..<30).map {
            SongEntry(title: "S\($0)", artist: "A",
                      timestamp: now.addingTimeInterval(Double(-$0)))
        }
        store.seed(entries, for: "s")
        XCTAssertEqual(store.entries(for: "s").count, 20)
    }
}
