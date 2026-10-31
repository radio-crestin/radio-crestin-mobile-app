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
    /// listeners so the expected order is plain to read. It keeps no
    /// catalog between launches: every test starts from the network.
    private func makeAppState() -> AppState {
        let suite = "AppStateListOrderTests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suite)
            StubAPIProtocol.reset()
        }
        let appState = AppState(
            repository: StubAPIProtocol.repository(),
            defaults: UserDefaults(suiteName: suite) ?? .standard,
            catalogCache: StationCatalogCache(fileURL: nil)
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
