import XCTest
@testable import RadioCrestinTV

/// The grids keep the order they showed (E7) while station values update,
/// and previous / next without a browsing snapshot walk "Posturi" as shown.
///
/// `AppState` loads its catalog from a stubbed API. These tests stay off
/// `selectStation` and favourites: both send PostHog events, and the test
/// host app sets PostHog up with the production project.
@MainActor
final class AppStateListOrderTests: XCTestCase {

    private func station(
        _ id: Int,
        title: String? = nil,
        listeners: Int
    ) -> Station {
        Station(
            id: id,
            slug: "s\(id)",
            title: title ?? "S\(id)",
            order: 0,
            thumbnailUrl: nil,
            totalListeners: listeners,
            stationStreams: [
                StationStream(order: 0, type: "MP3",
                              streamUrl: "https://x/s\(id).mp3"),
            ],
            uptime: Uptime(isUp: true, timestamp: nil),
            nowPlaying: nil,
            reviewsStats: nil,
            stationType: nil,
            playlistItems: nil,
            hlsDvrStreamUrl: nil
        )
    }

    /// An `AppState` on its own defaults and the stubbed API, sorted by
    /// listeners so the expected order is plain to read.
    private func makeAppState() -> AppState {
        let suite = "AppStateListOrderTests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suite)
            StubAPIProtocol.reset()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAPIProtocol.self]
        let session = URLSession(configuration: configuration)
        let appState = AppState(
            repository: StationRepository(
                client: RestClient(session: session)
            ),
            defaults: UserDefaults(suiteName: suite) ?? .standard
        )
        appState.sortOption = .listeners
        return appState
    }

    /// Serves `catalog` and runs a full refresh, as a launch or a return
    /// to the app does.
    private func load(
        _ catalog: [Station],
        into appState: AppState
    ) async throws {
        try StubAPIProtocol.serve(catalog)
        await appState.loadStations()
        XCTAssertNil(appState.loadError)
    }

    private func shownIds(_ appState: AppState) -> [Int] {
        appState.displayedStations(in: .all).map(\.id)
    }

    // MARK: - Stable order (E7)

    func test_the_grid_keeps_its_order_when_listener_counts_change() async throws {
        let appState = makeAppState()
        try await load(
            [station(1, listeners: 30), station(2, listeners: 20),
             station(3, listeners: 10)],
            into: appState
        )
        XCTAssertEqual(shownIds(appState), [1, 2, 3])

        try await load(
            [station(1, listeners: 30), station(2, listeners: 20),
             station(3, listeners: 99)],
            into: appState
        )

        XCTAssertEqual(shownIds(appState), [1, 2, 3])
        XCTAssertEqual(
            appState.displayedStations(in: .all).last?.totalListeners, 99
        )
        XCTAssertEqual(appState.sortedStations.map(\.id), [3, 1, 2])
    }

    func test_new_stations_join_at_the_end_and_removed_ones_leave() async throws {
        let appState = makeAppState()
        try await load(
            [station(1, listeners: 30), station(2, listeners: 20),
             station(3, listeners: 10)],
            into: appState
        )

        try await load(
            [station(1, listeners: 30), station(3, listeners: 10),
             station(4, listeners: 50)],
            into: appState
        )

        XCTAssertEqual(shownIds(appState), [1, 3, 4])
    }

    func test_switching_to_the_tab_ranks_it_again() async throws {
        let appState = makeAppState()
        try await load(
            [station(1, listeners: 30), station(2, listeners: 20),
             station(3, listeners: 10)],
            into: appState
        )
        try await load(
            [station(1, listeners: 30), station(2, listeners: 20),
             station(3, listeners: 99)],
            into: appState
        )

        appState.refreshOrder(of: .all)

        XCTAssertEqual(shownIds(appState), [3, 1, 2])
    }

    func test_changing_the_sort_ranks_the_grid_again() async throws {
        let appState = makeAppState()
        try await load(
            [station(1, title: "Zorii", listeners: 30),
             station(2, title: "Bucuria", listeners: 20),
             station(3, title: "Alfa", listeners: 10)],
            into: appState
        )
        XCTAssertEqual(shownIds(appState), [1, 2, 3])

        appState.sortOption = .alphabetical

        XCTAssertEqual(shownIds(appState), [3, 2, 1])
    }

    // MARK: - Previous / next without a browsing snapshot

    /// Four stations, so the order shown and the live ranking are not just
    /// rotations of each other (which would have the same neighbours).
    func test_next_and_previous_walk_posturi_as_shown_and_wrap() async throws {
        let appState = makeAppState()
        try await load(
            [station(1, listeners: 40), station(2, listeners: 30),
             station(3, listeners: 20), station(4, listeners: 10)],
            into: appState
        )
        // Ranked live, 2 would now come after 3.
        try await load(
            [station(1, listeners: 40), station(2, listeners: 15),
             station(3, listeners: 20), station(4, listeners: 10)],
            into: appState
        )
        XCTAssertEqual(shownIds(appState), [1, 2, 3, 4])
        XCTAssertEqual(appState.sortedStations.map(\.id), [1, 3, 2, 4])

        let byId = Dictionary(
            uniqueKeysWithValues: appState.stations.map { ($0.id, $0) }
        )
        let first = try XCTUnwrap(byId[1])
        let third = try XCTUnwrap(byId[3])
        let last = try XCTUnwrap(byId[4])

        XCTAssertEqual(appState.nextStation(after: first)?.id, 2)
        XCTAssertEqual(appState.previousStation(before: third)?.id, 2)
        XCTAssertEqual(appState.nextStation(after: last)?.id, 1)
        XCTAssertEqual(appState.previousStation(before: first)?.id, 4)
    }
}

// MARK: - Stubbed API

/// Answers the app's REST calls without the network: `/stations` with the
/// catalog a test serves, the metadata and private-station endpoints with
/// empty lists, anything else (song history) with 404.
private final class StubAPIProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stationsBody = Data()

    static func serve(_ catalog: [Station]) throws {
        let stations = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(catalog)
        )
        let body = try JSONSerialization.data(
            withJSONObject: ["data": ["stations": stations]]
        )
        lock.withLock { stationsBody = body }
    }

    static func reset() {
        lock.withLock { stationsBody = Data() }
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

    override func stopLoading() {}

    private static func response(for path: String) -> (Int, Data) {
        switch path {
        case "/api/v1/stations":
            return (200, lock.withLock { stationsBody })
        case "/api/v1/stations-metadata":
            return (200, Data(#"{"data":{"stations_metadata":[]}}"#.utf8))
        case "/api/v1/private-stations":
            return (200, Data(#"{"data":{"stations":[]}}"#.utf8))
        default:
            return (404, Data("{}".utf8))
        }
    }
}
