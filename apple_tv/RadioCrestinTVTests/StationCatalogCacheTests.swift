import XCTest
@testable import RadioCrestinTV

/// The catalog saved for the next launch keeps what describes the
/// stations, never the song each one played when it was saved.
final class StationCatalogCacheTests: XCTestCase {

    /// A cache in a file of its own, removed after the test.
    private func makeCache() -> StationCatalogCache {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StationCatalogCacheTests-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return StationCatalogCache(fileURL: url)
    }

    private func station(_ id: Int, song: String? = nil) -> Station {
        Station(
            id: id,
            slug: "s\(id)",
            title: "S\(id)",
            order: id,
            thumbnailUrl: "https://x/s\(id).png",
            totalListeners: 10 * id,
            stationStreams: [
                StationStream(order: 0, type: "HLS",
                              streamUrl: "https://x/s\(id).m3u8"),
            ],
            uptime: Uptime(isUp: true, timestamp: nil),
            nowPlaying: song.map {
                NowPlaying(
                    id: 1,
                    timestamp: "2026-10-30T21:34:46.041615+00:00",
                    song: Song(id: 1, name: $0, thumbnailUrl: nil, artist: nil)
                )
            },
            reviewsStats: ReviewsStats(averageRating: 4.5, numberOfReviews: 2),
            stationType: nil,
            playlistItems: nil,
            hlsDvrStreamUrl: nil
        )
    }

    func test_a_saved_catalog_comes_back_without_its_songs() async throws {
        let cache = makeCache()

        await cache.save([station(1, song: "Psalmul 23"), station(2)])

        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.map(\.id), [1, 2])
        XCTAssertEqual(loaded.map(\.songTitle), ["", ""])
        XCTAssertNil(loaded[0].nowPlaying)
        XCTAssertEqual(loaded[0].stationStreams, station(1).stationStreams)
        XCTAssertEqual(loaded[0].totalListeners, 10)
        XCTAssertEqual(loaded[0].reviewCount, 2)
    }

    func test_a_new_save_replaces_the_last_one() async throws {
        let cache = makeCache()
        await cache.save([station(1), station(2)])

        await cache.save([station(3)])

        XCTAssertEqual(try XCTUnwrap(cache.load()).map(\.id), [3])
    }

    func test_nothing_saved_loads_nothing() {
        XCTAssertNil(makeCache().load())
    }

    func test_a_save_that_no_longer_decodes_loads_nothing() throws {
        let cache = makeCache()
        let url = try XCTUnwrap(cache.fileURL)
        try Data(#"[{"id":1}]"#.utf8).write(to: url)

        XCTAssertNil(cache.load())
    }

    func test_an_empty_catalog_does_not_replace_the_last_one() async throws {
        let cache = makeCache()
        await cache.save([station(1)])

        await cache.save([])

        XCTAssertEqual(try XCTUnwrap(cache.load()).map(\.id), [1])
    }

    func test_without_a_file_nothing_is_kept() async {
        let cache = StationCatalogCache(fileURL: nil)

        await cache.save([station(1)])

        XCTAssertNil(cache.load())
    }
}
