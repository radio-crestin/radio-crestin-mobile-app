import XCTest
@testable import RadioCrestinTV

/// The reviews a like or a dislike sends, as the phone sends them
/// (`lib/services/review_service.dart`), and what a refusal does: it is
/// reported, never thrown. Every request goes to `ReviewStubProtocol`.
final class ReviewServiceTests: XCTestCase {

    private let failures = ReportedFailures()

    override func tearDown() {
        ReviewStubProtocol.reset()
    }

    private func send(_ request: ReviewRequest) async {
        await ReviewStubProtocol.service(reportFailure: failures.record)
            .send(request)
    }

    private func onlyRequest() throws -> ReviewStubProtocol.Request {
        let received = ReviewStubProtocol.received
        XCTAssertEqual(received.count, 1)
        return try XCTUnwrap(received.first)
    }

    func test_a_review_is_a_json_post_to_reviews() async throws {
        await send(.submit(
            stationId: 12, stars: 5, message: "I like: Har - Cor", songId: 990003
        ))

        let request = try onlyRequest()
        XCTAssertEqual(
            request.url.absoluteString, "\(ReviewStubProtocol.baseURL)/reviews/"
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertEqual(request.body.count, 5)
        XCTAssertEqual(request.body["station_id"] as? Int, 12)
        XCTAssertEqual(request.body["stars"] as? Int, 5)
        XCTAssertEqual(request.body["message"] as? String, "I like: Har - Cor")
        XCTAssertEqual(request.body["user_identifier"] as? String, "test-device")
        XCTAssertEqual(request.body["song_id"] as? Int, 990003)
        XCTAssertTrue(failures.all.isEmpty)
    }

    /// As on the phone, only an id the API knows goes along: a play of the
    /// song history shows with id 0.
    func test_a_song_without_an_id_is_sent_without_song_id() async throws {
        await send(.submit(stationId: 12, stars: 1, message: "m", songId: 0))
        await send(.submit(stationId: 12, stars: 1, message: "m", songId: nil))

        let received = ReviewStubProtocol.received
        XCTAssertEqual(received.count, 2)
        for request in received {
            XCTAssertNil(request.body["song_id"])
            XCTAssertEqual(request.body["station_id"] as? Int, 12)
        }
    }

    func test_taking_a_rating_back_posts_the_station_and_song_to_delete() async throws {
        await send(.delete(stationId: 12, songId: 990003))

        let request = try onlyRequest()
        XCTAssertEqual(
            request.url.absoluteString,
            "\(ReviewStubProtocol.baseURL)/reviews/delete/"
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        // The API finds the review by the caller's address, station and
        // song: the phone sends no device here.
        XCTAssertEqual(request.body.count, 2)
        XCTAssertEqual(request.body["station_id"] as? Int, 12)
        XCTAssertEqual(request.body["song_id"] as? Int, 990003)
        XCTAssertTrue(failures.all.isEmpty)
    }

    func test_taking_a_station_rating_back_sends_the_station_alone() async throws {
        await send(.delete(stationId: 12, songId: nil))

        let request = try onlyRequest()
        XCTAssertEqual(request.body.count, 1)
        XCTAssertEqual(request.body["station_id"] as? Int, 12)
    }

    func test_an_http_error_is_reported_with_the_station_never_the_device() async throws {
        ReviewStubProtocol.serve(status: 500, body: "{}")

        await send(.submit(stationId: 12, stars: 5, message: "m", songId: 7))

        let failure = try XCTUnwrap(failures.all.first)
        XCTAssertEqual(failures.all.count, 1)
        XCTAssertEqual(failure.context, "review_submit")
        guard case ReviewError.http(500) = failure.error else {
            return XCTFail("\(failure.error)")
        }
        XCTAssertEqual(failure.extra["station_id"] as? Int, 12)
        XCTAssertEqual(failure.extra["song_id"] as? Int, 7)
        XCTAssertFalse(failure.extra.values.contains { "\($0)" == "test-device" })
    }

    /// The API answers 200 with an `OperationInfo` when it refuses the
    /// input, as the phone reads it.
    func test_an_operation_info_answer_is_reported_with_its_message() async throws {
        ReviewStubProtocol.serve(status: 200, body: """
        {"data":{"submit_review":{"__typename":"OperationInfo",\
        "messages":[{"message":"Song not found"}]}}}
        """)

        await send(.submit(stationId: 12, stars: 5, message: "m", songId: 7))

        let failure = try XCTUnwrap(failures.all.first)
        guard case ReviewError.rejected("Song not found") = failure.error else {
            return XCTFail("\(failure.error)")
        }
    }

    /// A delete of a review the API does not have answers success false.
    func test_an_unsuccessful_delete_is_reported() async throws {
        ReviewStubProtocol.serve(status: 200, body: """
        {"data":{"delete_review":{"__typename":"DeleteReviewResponse",\
        "success":false,"message":"Review not found"}}}
        """)

        await send(.delete(stationId: 12, songId: 7))

        let failure = try XCTUnwrap(failures.all.first)
        XCTAssertEqual(failure.context, "review_delete")
        guard case ReviewError.rejected("Review not found") = failure.error else {
            return XCTFail("\(failure.error)")
        }
    }

    func test_an_answer_without_the_outcome_is_reported() async throws {
        ReviewStubProtocol.serve(status: 200, body: #"{"data":{}}"#)

        await send(.submit(stationId: 12, stars: 5, message: "m", songId: 7))

        let failure = try XCTUnwrap(failures.all.first)
        guard case ReviewError.unreadableAnswer = failure.error else {
            return XCTFail("\(failure.error)")
        }
    }

    func test_the_api_out_of_reach_is_reported() async throws {
        ReviewStubProtocol.failRequests(URLError(.notConnectedToInternet))

        await send(.delete(stationId: 12, songId: 7))

        let failure = try XCTUnwrap(failures.all.first)
        XCTAssertEqual((failure.error as? URLError)?.code, .notConnectedToInternet)
    }
}
