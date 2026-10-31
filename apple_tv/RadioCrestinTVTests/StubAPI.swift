import Foundation
@testable import RadioCrestinTV

/// Answers the app's REST calls without the network: `/stations` with the
/// catalog a test serves, `/stations-metadata` with the payload it serves
/// (none by default), the private-station endpoint with an empty list,
/// the song history it serves (404 by default), anything else with 404.
/// Notes every URL asked for.
final class StubAPIProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stationsBody = Data()
    private static var metadataBody = emptyMetadata
    private static var historyBody: Data?
    private static var requests: [URL] = []
    private static var latency: TimeInterval = 0
    private static var unreachablePaths: Set<String> = []

    private static let emptyMetadata =
        Data(#"{"data":{"stations_metadata":[]}}"#.utf8)

    /// A repository whose requests this stub answers.
    static func repository() -> StationRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAPIProtocol.self]
        return StationRepository(
            client: RestClient(session: URLSession(configuration: configuration))
        )
    }

    static func serve(_ catalog: [Station]) throws {
        let stations = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(catalog)
        )
        let body = try JSONSerialization.data(
            withJSONObject: ["data": ["stations": stations]]
        )
        lock.withLock { stationsBody = body }
    }

    /// Serves `/stations-metadata` entries, each shaped as the API sends
    /// one: `id`, `uptime`, `now_playing`.
    static func serveMetadata(_ entries: [[String: Any]]) throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["data": ["stations_metadata": entries]]
        )
        lock.withLock { metadataBody = body }
    }

    /// Serves `/stations-metadata-history` with `entries`, oldest first as
    /// the API sends them, each with `timestamp` and `song`.
    static func serveHistory(_ entries: [[String: Any]]) throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "data": ["stations_metadata_history": ["history": entries]],
        ])
        lock.withLock { historyBody = body }
    }

    /// Answers every request `seconds` late, so a test can act while a
    /// sync waits for the API.
    static func answer(after seconds: TimeInterval) {
        lock.withLock { latency = seconds }
    }

    /// Fails the requests to `path` (e.g. `/api/v1/stations-metadata`) as
    /// with the API out of reach, or with `false`, answers them again.
    static func setUnreachable(_ path: String, _ unreachable: Bool = true) {
        lock.withLock {
            if unreachable {
                unreachablePaths.insert(path)
            } else {
                unreachablePaths.remove(path)
            }
        }
    }

    /// Every URL asked for since the last `reset()`, in order.
    static var requestedURLs: [URL] {
        lock.withLock { requests }
    }

    static func reset() {
        lock.withLock {
            stationsBody = Data()
            metadataBody = emptyMetadata
            historyBody = nil
            requests = []
            latency = 0
            unreachablePaths = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let delay = Self.lock.withLock {
            Self.requests.append(url)
            return Self.latency
        }
        guard delay > 0 else {
            answer(url)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            self.answer(url)
        }
    }

    override func stopLoading() {}

    private func answer(_ url: URL) {
        guard !Self.lock.withLock({ Self.unreachablePaths.contains(url.path) })
        else {
            client?.urlProtocol(
                self, didFailWithError: URLError(.notConnectedToInternet)
            )
            return
        }
        let (status, body) = Self.response(for: url.path)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
            client?.urlProtocol(
                self, didReceive: response, cacheStoragePolicy: .notAllowed
            )
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func response(for path: String) -> (Int, Data) {
        switch path {
        case "/api/v1/stations":
            return (200, lock.withLock { stationsBody })
        case "/api/v1/stations-metadata":
            return (200, lock.withLock { metadataBody })
        case "/api/v1/private-stations":
            return (200, Data(#"{"data":{"stations":[]}}"#.utf8))
        case "/api/v1/stations-metadata-history":
            return lock.withLock { historyBody }.map { (200, $0) }
                ?? (404, Data("{}".utf8))
        default:
            return (404, Data("{}".utf8))
        }
    }
}
