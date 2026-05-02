import XCTest
@testable import RadioCrestinTV

final class StationModelTests: XCTestCase {

    func makeStation(
        id: Int = 1,
        slug: String = "radio-x",
        title: String = "Radio X",
        order: Int = 0,
        thumbnailUrl: String? = "https://example.com/logo.png",
        totalListeners: Int? = 10,
        streams: [StationStream] = [
            StationStream(order: 0, type: "MP3", streamUrl: "https://x/a.mp3"),
        ],
        uptime: Uptime? = Uptime(isUp: true, timestamp: nil),
        nowPlaying: NowPlaying? = nil,
        reviewsStats: ReviewsStats? = nil
    ) -> Station {
        Station(
            id: id, slug: slug, title: title, order: order,
            thumbnailUrl: thumbnailUrl,
            totalListeners: totalListeners,
            stationStreams: streams,
            uptime: uptime,
            nowPlaying: nowPlaying,
            reviewsStats: reviewsStats
        )
    }

    // MARK: - Codable

    func test_decodes_from_canonical_API_payload() throws {
        let json = """
        {
          "id": 1, "slug": "radio-emanuel", "title": "Radio Emanuel", "order": 5,
          "thumbnail_url": "https://e.com/logo.png",
          "total_listeners": 42,
          "station_streams": [
            { "order": 0, "type": "HLS", "stream_url": "https://e/h.m3u8" },
            { "order": 1, "type": "MP3", "stream_url": "https://e/a.mp3" }
          ],
          "uptime": { "is_up": true, "timestamp": "2026-04-15T10:00:00Z" },
          "now_playing": null,
          "reviews_stats": { "average_rating": 4.5, "number_of_reviews": 12 }
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Station.self, from: json)
        XCTAssertEqual(s.id, 1)
        XCTAssertEqual(s.slug, "radio-emanuel")
        XCTAssertEqual(s.totalListeners, 42)
        XCTAssertEqual(s.stationStreams.count, 2)
        XCTAssertEqual(s.uptime?.isUp, true)
        XCTAssertEqual(s.reviewCount, 12)
        XCTAssertEqual(s.averageRating, 4.5, accuracy: 0.001)
    }

    // MARK: - Computed properties

    func test_isUp_defaults_to_true_when_uptime_missing() {
        let s = makeStation(uptime: nil)
        XCTAssertTrue(s.isUp)
    }

    func test_isUp_reflects_uptime_flag() {
        XCTAssertFalse(makeStation(uptime: Uptime(isUp: false, timestamp: nil)).isUp)
    }

    func test_orderedStreams_sorts_by_order() {
        let s = makeStation(streams: [
            StationStream(order: 2, type: "MP3", streamUrl: "c"),
            StationStream(order: 0, type: "HLS", streamUrl: "a"),
            StationStream(order: 1, type: "MP3", streamUrl: "b"),
        ])
        XCTAssertEqual(s.orderedStreams.map(\.streamUrl), ["a", "b", "c"])
    }

    func test_primaryStreamIsHls_uses_lowest_order_stream() {
        let hlsFirst = makeStation(streams: [
            StationStream(order: 0, type: "HLS", streamUrl: "a"),
            StationStream(order: 1, type: "MP3", streamUrl: "b"),
        ])
        XCTAssertTrue(hlsFirst.primaryStreamIsHls)

        let mp3First = makeStation(streams: [
            StationStream(order: 1, type: "HLS", streamUrl: "a"),
            StationStream(order: 0, type: "MP3", streamUrl: "b"),
        ])
        XCTAssertFalse(mp3First.primaryStreamIsHls)
    }

    func test_song_helpers_return_empty_when_no_now_playing() {
        let s = makeStation(nowPlaying: nil)
        XCTAssertEqual(s.songTitle, "")
        XCTAssertEqual(s.songArtist, "")
        XCTAssertNil(s.songThumbnailUrl)
    }

    func test_song_thumbnail_falls_back_to_artist_thumbnail() {
        let np = NowPlaying(
            id: 1, timestamp: nil,
            song: Song(
                id: 9, name: "Hymn",
                thumbnailUrl: nil,
                artist: Artist(id: 1, name: "Choir",
                               thumbnailUrl: "https://x/artist.png")
            )
        )
        let s = makeStation(nowPlaying: np)
        XCTAssertEqual(s.songThumbnailUrl, "https://x/artist.png")
    }

    func test_displayThumbnailURLs_drops_invalid_and_nil() {
        let s = makeStation(thumbnailUrl: "https://x/logo.png")
        let urls = s.displayThumbnailURLs
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.absoluteString, "https://x/logo.png")
    }

    func test_reviewScore_is_average_times_count() {
        let s = makeStation(reviewsStats:
            ReviewsStats(averageRating: 4.0, numberOfReviews: 5))
        XCTAssertEqual(s.reviewScore, 20.0, accuracy: 0.001)
    }

    func test_reviewScore_zero_when_no_reviews() {
        let s = makeStation(reviewsStats: nil)
        XCTAssertEqual(s.reviewScore, 0.0)
    }

    // MARK: - merging(_:liveListeners:)

    // The merging() helper takes a StationMetadata decoded from the
    // /stations-metadata API. Decode a JSON fixture so we don't depend on
    // the (potentially private) memberwise initializer.
    private func metadata(uptimeUp: Bool? = nil,
                          songName: String? = nil,
                          listeners: Int? = nil) throws -> StationMetadata {
        var dict: [String: Any] = ["id": 1]
        if let up = uptimeUp {
            dict["uptime"] = ["is_up": up, "timestamp": "ts"]
        }
        var np: [String: Any] = [:]
        if let n = songName {
            np["song"] = ["id": 1, "name": n]
        }
        if let l = listeners {
            np["listeners"] = l
        }
        if !np.isEmpty {
            dict["now_playing"] = np
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(StationMetadata.self, from: data)
    }

    func test_merging_replaces_uptime_and_nowPlaying() throws {
        let original = makeStation(
            uptime: Uptime(isUp: true, timestamp: "old"),
            nowPlaying: nil
        )
        let m = try metadata(uptimeUp: false, songName: "X", listeners: 33)
        let merged = original.merging(m, liveListeners: nil)
        XCTAssertEqual(merged.uptime?.isUp, false)
        XCTAssertEqual(merged.nowPlaying?.song?.name, "X")
        XCTAssertEqual(merged.totalListeners, 33)
    }

    func test_merging_prefers_liveListeners_over_metadata_listeners() throws {
        let original = makeStation(totalListeners: 1)
        let m = try metadata(songName: "Y", listeners: 99)
        let merged = original.merging(m, liveListeners: 7)
        XCTAssertEqual(merged.totalListeners, 7)
    }

    func test_merging_falls_back_to_existing_listeners() throws {
        let original = makeStation(totalListeners: 5)
        let m = try metadata(songName: "Z")  // listeners nil
        let merged = original.merging(m, liveListeners: nil)
        XCTAssertEqual(merged.totalListeners, 5)
    }
}
