import XCTest
@testable import RadioCrestinTV

/// `order` on a stream is a ranking hint, never an array index. Production
/// data routinely ships gaps (0 and 2, no 1 — 43 of 64 stations) and
/// occasional duplicates, so the fallback walk must be driven by array
/// position after an explicit sort.
final class StationStreamOrderTests: XCTestCase {

    private func station(_ streams: [StationStream]) -> Station {
        Station(
            id: 1, slug: "s", title: "S", order: 0,
            thumbnailUrl: nil, totalListeners: nil,
            stationStreams: streams,
            uptime: nil, nowPlaying: nil, reviewsStats: nil,
            stationType: nil, playlistItems: nil, hlsDvrStreamUrl: nil
        )
    }

    func test_non_contiguous_orders_keep_every_stream_in_rank_order() {
        // The exact production shape of radio-micul-samaritean /
        // radio-calea-spre-cer-popular: order 0 then order 2, no 1.
        let result = station([
            StationStream(order: 2, type: "direct_stream", streamUrl: "https://a/x.mp3"),
            StationStream(order: 0, type: "HLS", streamUrl: "https://a/i.m3u8")
        ]).orderedStreams

        XCTAssertEqual(result.count, 2, "a gap must not drop a stream")
        XCTAssertEqual(result[0].type, "HLS")
        XCTAssertEqual(result[1].type, "direct_stream")
    }

    func test_large_and_negative_orders_are_ranked_not_indexed() {
        let result = station([
            StationStream(order: 900, type: "c", streamUrl: "https://a/3"),
            StationStream(order: -5, type: "a", streamUrl: "https://a/1"),
            StationStream(order: 17, type: "b", streamUrl: "https://a/2")
        ]).orderedStreams
        XCTAssertEqual(result.map(\.type), ["a", "b", "c"])
    }

    func test_duplicate_orders_keep_wire_order_between_the_ties() {
        let result = station([
            StationStream(order: 0, type: "HLS", streamUrl: "https://a/first"),
            StationStream(order: 0, type: "direct_stream", streamUrl: "https://a/second")
        ]).orderedStreams
        XCTAssertEqual(result.map(\.streamUrl),
                       ["https://a/first", "https://a/second"])
    }

    func test_unusable_streams_are_dropped_before_the_fallback_walk() {
        let result = station([
            StationStream(order: 0, type: "HLS", streamUrl: "   "),
            StationStream(order: 1, type: "direct_stream", streamUrl: "https://a/ok.mp3"),
            StationStream(order: 2, type: "direct_stream", streamUrl: "")
        ]).orderedStreams
        XCTAssertEqual(result.map(\.streamUrl), ["https://a/ok.mp3"])
    }

    func test_repeated_urls_do_not_burn_a_second_fallback_attempt() {
        let result = station([
            StationStream(order: 0, type: "HLS", streamUrl: "https://a/i.m3u8"),
            StationStream(order: 1, type: "HLS", streamUrl: "https://a/i.m3u8"),
            StationStream(order: 2, type: "direct_stream", streamUrl: "https://a/x.mp3")
        ]).orderedStreams
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].streamUrl, "https://a/x.mp3")
    }

    func test_primary_stream_detection_follows_rank_not_wire_position() {
        let s = station([
            StationStream(order: 2, type: "direct_stream", streamUrl: "https://a/x.mp3"),
            StationStream(order: 0, type: "HLS", streamUrl: "https://a/i.m3u8")
        ])
        XCTAssertTrue(s.primaryStreamIsHls)
    }
}
