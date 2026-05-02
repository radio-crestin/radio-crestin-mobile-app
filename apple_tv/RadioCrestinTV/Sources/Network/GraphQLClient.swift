import Foundation

/// REST client + timestamp helpers shared with the Flutter app.
///
/// History note: this file was originally a GraphQL client (the public
/// Hasura endpoint). The mobile app moved to REST under `/api/v1` so the
/// metadata fetches can be parameterised with a 10s-aligned `timestamp`
/// query argument — that timestamp is used to align the `now_playing`
/// metadata with the actual audio the user is hearing (HLS streams have
/// a few-second buffer; direct MP3 plays live). The Apple TV app now
/// follows the same contract; the file keeps its old name to avoid
/// editing the Xcode project.

enum APIError: Error, LocalizedError {
    case invalidURL
    case http(Int)
    case empty
    case decoding(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "API endpoint URL is malformed"
        case .http(let code): return "HTTP \(code) from API"
        case .empty: return "Empty response from API"
        case .decoding(let err): return "Decoding failed: \(err)"
        }
    }
}

/// Returns a Unix timestamp (seconds) rounded to the nearest 10 seconds.
/// Matches `getRoundedTimestamp` in `lib/utils/api_utils.dart` so the
/// server-side cache used by the radiocrestin.ro web client stays warm.
func roundedTimestamp(at date: Date = Date(), offset: TimeInterval = 0) -> Int {
    let epoch = Int(date.timeIntervalSince1970 - offset)
    return (epoch / 10) * 10
}

/// Thin REST wrapper that decodes a `Decodable` payload from a URL.
/// Adds an 8s timeout so a slow API doesn't stall the metadata poller.
struct RestClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func get<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.empty
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw APIError.empty }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}

/// Base URL for the public mobile-app API. Mirrors `lib/constants.dart`.
enum API {
    static let base = "https://api.radiocrestin.ro/api/v1"
    static let stationsURL = "\(base)/stations"
    static let stationsMetadataURL = "\(base)/stations-metadata"
}
