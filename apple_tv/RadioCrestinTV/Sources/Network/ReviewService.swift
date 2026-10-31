import Foundation

/// What the API is told when the listener likes or dislikes a song.
enum ReviewRequest: Equatable {
    /// A review of the station, about its song when `songId` is set: 5
    /// stars for a like, 1 for a dislike.
    case submit(stationId: Int, stars: Int, message: String, songId: Int?)
    /// Takes back the review of the station's song (`songId`), or of the
    /// station itself without one.
    case delete(stationId: Int, songId: Int?)
}

/// Why the API did not take a review. Reported to analytics only: nothing
/// on screen waits for a review.
enum ReviewError: Error, LocalizedError {
    case http(Int)
    /// The API answered, but said no: its own words.
    case rejected(String)
    /// An answer without the outcome the request asks for.
    case unreadableAnswer

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code) from the reviews API"
        case .rejected(let message): return "Review rejected: \(message)"
        case .unreadableAnswer: return "Unreadable answer from the reviews API"
        }
    }
}

/// Sends likes and dislikes to the API as reviews, as the phone does
/// (`lib/services/review_service.dart`): a JSON POST to `/reviews/` with
/// the station, the stars, the message, the device and the song when it
/// has an id, and one to `/reviews/delete/` with the station and the song
/// to take it back. The API keeps one review per listener (by IP),
/// station and song, so a dislike after a like replaces it.
///
/// Fire and forget: a failure goes to `reportFailure` (analytics by
/// default), never to the screen.
struct ReviewService {
    /// Takes a failure, where it happened (`review_submit` or
    /// `review_delete`) and the station and song the request named.
    typealias FailureReporter =
        (Error, _ context: String, _ extra: [String: Any]) -> Void

    private let session: URLSession
    private let baseURL: String
    private let userIdentifier: () -> String
    private let reportFailure: FailureReporter

    init(
        session: URLSession = .shared,
        baseURL: String = API.base,
        userIdentifier: @escaping () -> String = { DeviceIdentity.deviceId },
        reportFailure: @escaping FailureReporter = {
            Analytics.captureError($0, context: $1, extra: $2)
        }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.userIdentifier = userIdentifier
        self.reportFailure = reportFailure
    }

    /// Sends `request`, reporting a failure rather than throwing it.
    func send(_ request: ReviewRequest) async {
        do {
            try await post(request)
        } catch {
            reportFailure(
                error, request.analyticsContext, request.analyticsExtra
            )
        }
    }

    private func post(_ request: ReviewRequest) async throws {
        guard let url = URL(string: baseURL + request.path) else {
            throw APIError.invalidURL
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue(
            "application/json", forHTTPHeaderField: "Content-Type"
        )
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: body(of: request),
            options: [.sortedKeys]
        )
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ReviewError.unreadableAnswer
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReviewError.http(http.statusCode)
        }
        try Self.checkOutcome(data, field: request.outcomeField)
    }

    /// The JSON body: the phone's fields, `song_id` only for a song the
    /// API knows (an id above 0), and the device only on a review.
    func body(of request: ReviewRequest) -> [String: Any] {
        switch request {
        case let .submit(stationId, stars, message, songId):
            var body: [String: Any] = [
                "station_id": stationId,
                "stars": stars,
                "message": message,
                "user_identifier": userIdentifier(),
            ]
            if let songId, songId > 0 { body["song_id"] = songId }
            return body
        case let .delete(stationId, songId):
            var body: [String: Any] = ["station_id": stationId]
            if let songId, songId > 0 { body["song_id"] = songId }
            return body
        }
    }

    /// Throws unless the answer reports the review taken: the API answers
    /// 200 with `data.<field>`, an `OperationInfo` (its messages) or a
    /// `success` of false when it refuses one.
    static func checkOutcome(_ data: Data, field: String) throws {
        let root = try? JSONSerialization.jsonObject(with: data)
        let answer = (root as? [String: Any])?["data"] as? [String: Any]
        guard let outcome = answer?[field] as? [String: Any] else {
            throw ReviewError.unreadableAnswer
        }
        if outcome["__typename"] as? String == "OperationInfo" {
            let messages = outcome["messages"] as? [[String: Any]]
            throw ReviewError.rejected(
                messages?.first?["message"] as? String ?? "OperationInfo"
            )
        }
        if outcome["success"] as? Bool == false {
            throw ReviewError.rejected(outcome["message"] as? String ?? "")
        }
    }
}

private extension ReviewRequest {
    var path: String {
        switch self {
        case .submit: return "/reviews/"
        case .delete: return "/reviews/delete/"
        }
    }

    /// The field of `data` the API answers in.
    var outcomeField: String {
        switch self {
        case .submit: return "submit_review"
        case .delete: return "delete_review"
        }
    }

    var analyticsContext: String {
        switch self {
        case .submit: return "review_submit"
        case .delete: return "review_delete"
        }
    }

    /// The station and the song, never the device.
    var analyticsExtra: [String: Any] {
        switch self {
        case let .submit(stationId, stars, _, songId):
            return [
                "station_id": stationId, "stars": stars, "song_id": songId ?? 0,
            ]
        case let .delete(stationId, songId):
            return ["station_id": stationId, "song_id": songId ?? 0]
        }
    }
}
