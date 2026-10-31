import XCTest
@testable import RadioCrestinTV

/// A launch shows the catalog the last one saved at once, without its
/// songs, and keeps the order it showed when the network answers. Old
/// favorites saves take the order they were shown in.
///
/// Like `AppStateListOrderTests`, these stay off the paths that send
/// PostHog events (failed loads, `selectStation`, favorite toggles): the
/// test host app sets PostHog up with the production project. The failed
/// launch is covered on the simulator instead.
@MainActor
final class AppStateLaunchTests: XCTestCase {

    private var suite = ""
    private var defaults = UserDefaults.standard
    private var cache = StationCatalogCache(fileURL: nil)

    override func setUp() async throws {
        suite = "AppStateLaunchTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        cache = StationCatalogCache(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(suite).json")
        )
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        if let url = cache.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        StubAPIProtocol.reset()
    }

    /// A launch: an `AppState` on this test's defaults and saved catalog.
    private func launch() -> AppState {
        AppState(
            repository: StubAPIProtocol.repository(),
            defaults: defaults,
            catalogCache: cache
        )
    }

    private func station(
        _ id: Int,
        listeners: Int = 10,
        song: String? = nil
    ) -> Station {
        Station(
            id: id,
            slug: "s\(id)",
            title: "S\(id)",
            order: 0,
            thumbnailUrl: nil,
            totalListeners: listeners,
            stationStreams: [
                StationStream(order: 0, type: "MP3",
                              streamUrl: "https://x/s\(id).mp3"),
            ],
            uptime: Uptime(isUp: true, timestamp: nil),
            nowPlaying: song.map {
                NowPlaying(
                    id: 1,
                    timestamp: nil,
                    song: Song(id: 1, name: $0, thumbnailUrl: nil, artist: nil)
                )
            },
            reviewsStats: nil,
            stationType: nil,
            playlistItems: nil,
            hlsDvrStreamUrl: nil
        )
    }

    // MARK: - The saved catalog

    func test_the_saved_catalog_shows_at_launch_without_songs() async {
        await cache.save([station(1, song: "Psalmul 23"), station(2)])

        let appState = launch()

        XCTAssertEqual(appState.stations.map(\.id), [1, 2])
        XCTAssertEqual(appState.stations.map(\.songTitle), ["", ""])
        XCTAssertEqual(appState.displayedStations(in: .all).count, 2)
    }

    func test_the_refresh_fills_in_the_songs_and_keeps_the_order_shown() async throws {
        defaults.set(StationSort.listeners.rawValue, forKey: "tv.sortOption")
        await cache.save([
            station(1, listeners: 30), station(2, listeners: 20),
            station(3, listeners: 10),
        ])
        let appState = launch()
        XCTAssertEqual(appState.displayedStations(in: .all).map(\.id), [1, 2, 3])

        try StubAPIProtocol.serve([
            station(1, listeners: 30, song: "Psalmul 23"),
            station(2, listeners: 20), station(3, listeners: 99),
        ])
        await appState.loadStations()

        let shown = appState.displayedStations(in: .all)
        XCTAssertEqual(shown.map(\.id), [1, 2, 3])
        XCTAssertEqual(shown.first?.songTitle, "Psalmul 23")
        XCTAssertEqual(appState.sortedStations.map(\.id), [3, 1, 2])
    }

    func test_a_load_saves_the_catalog_for_the_next_launch() async throws {
        XCTAssertTrue(launch().stations.isEmpty)
        let first = launch()
        try StubAPIProtocol.serve([station(1, song: "Psalmul 23"), station(2)])

        await first.loadStations()

        let next = launch()
        XCTAssertEqual(next.stations.map(\.id), [1, 2])
        XCTAssertEqual(next.stations.map(\.songTitle), ["", ""])
    }

    func test_private_stations_from_the_last_launch_show_without_songs() throws {
        defaults.set(
            try JSONEncoder().encode([station(100, song: "Psalmul 23")]),
            forKey: "tv.privateStations"
        )

        let appState = launch()

        XCTAssertEqual(appState.stations.map(\.id), [100])
        XCTAssertEqual(appState.stations.first?.songTitle, "")
    }

    // MARK: - Favorites order

    func test_an_old_favorites_save_takes_the_order_it_was_shown_in() async {
        defaults.set(["s3", "s1"], forKey: "tv.favoriteSlugs")
        await cache.save([station(1), station(2), station(3)])

        let appState = launch()

        XCTAssertEqual(appState.favoriteStations.map(\.id), [1, 3])
        XCTAssertEqual(
            defaults.stringArray(forKey: "tv.favoriteSlugs"), ["s1", "s3"]
        )
        XCTAssertTrue(defaults.bool(forKey: "tv.favoriteOrderKept"))
    }

    func test_an_old_favorites_save_waits_for_the_first_catalog() async throws {
        defaults.set(["s3", "s1"], forKey: "tv.favoriteSlugs")
        let appState = launch()
        XCTAssertFalse(defaults.bool(forKey: "tv.favoriteOrderKept"))

        try StubAPIProtocol.serve([station(1), station(2), station(3)])
        await appState.loadStations()

        XCTAssertEqual(appState.favoriteStations.map(\.id), [1, 3])
        XCTAssertTrue(defaults.bool(forKey: "tv.favoriteOrderKept"))
    }

    func test_favorites_in_the_listeners_order_keep_it_across_launches() async {
        defaults.set(["s3", "s1"], forKey: "tv.favoriteSlugs")
        defaults.set(true, forKey: "tv.favoriteOrderKept")
        await cache.save([station(1), station(2), station(3)])

        XCTAssertEqual(launch().favoriteStations.map(\.id), [3, 1])
        XCTAssertEqual(launch().favoriteStations.map(\.id), [3, 1])
    }

    // MARK: - Load errors

    func test_no_internet_and_a_failing_api_read_differently() {
        let offline = "Nu ai conexiune la internet. "
            + "Verifică rețeaua și încearcă din nou."
        let server = "Serverul nu răspunde acum. "
            + "Încearcă din nou în câteva momente."

        for code: URLError.Code in [
            .notConnectedToInternet, .networkConnectionLost,
            .cannotFindHost, .dnsLookupFailed, .dataNotAllowed,
        ] {
            XCTAssertEqual(
                AppState.loadErrorMessage(for: URLError(code)), offline
            )
        }
        XCTAssertEqual(
            AppState.loadErrorMessage(for: URLError(.timedOut)), server
        )
        XCTAssertEqual(
            AppState.loadErrorMessage(for: APIError.http(404)), server
        )
        XCTAssertEqual(AppState.loadErrorMessage(for: APIError.empty), server)
    }
}
