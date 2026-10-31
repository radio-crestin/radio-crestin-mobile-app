import XCTest
@testable import RadioCrestinTV

/// "Favorite" lists the stations in the listener's order, as the phone
/// does: a new favorite goes last, and an old save keeps the order it was
/// shown in.
final class FavoriteListTests: XCTestCase {

    /// Stations with these slugs, in this order.
    private func catalog(_ slugs: String...) -> [Station] {
        slugs.enumerated().map { station($1, id: $0 + 1) }
    }

    private func station(_ slug: String, id: Int) -> Station {
        Station(
            id: id,
            slug: slug,
            title: slug.capitalized,
            order: 0,
            thumbnailUrl: nil,
            totalListeners: nil,
            stationStreams: [],
            uptime: nil,
            nowPlaying: nil,
            reviewsStats: nil,
            stationType: nil,
            playlistItems: nil,
            hlsDvrStreamUrl: nil
        )
    }

    // MARK: - Adding and removing

    func test_a_new_favorite_goes_last() {
        var favorites = FavoriteList(["eldad", "gosen"])

        let isFavorite = favorites.toggle("predic")

        XCTAssertTrue(isFavorite)
        XCTAssertEqual(favorites.slugs, ["eldad", "gosen", "predic"])
        XCTAssertTrue(favorites.contains("predic"))
    }

    func test_removing_one_keeps_the_others_in_their_order() {
        var favorites = FavoriteList(["eldad", "gosen", "predic"])

        let isFavorite = favorites.toggle("gosen")

        XCTAssertFalse(isFavorite)
        XCTAssertEqual(favorites.slugs, ["eldad", "predic"])
        XCTAssertFalse(favorites.contains("gosen"))
    }

    func test_a_station_added_again_goes_last() {
        var favorites = FavoriteList(["eldad", "gosen", "predic"])

        _ = favorites.toggle("eldad")
        _ = favorites.toggle("eldad")

        XCTAssertEqual(favorites.slugs, ["gosen", "predic", "eldad"])
    }

    func test_a_save_with_duplicates_keeps_the_first() {
        let favorites = FavoriteList(["eldad", "gosen", "eldad"])

        XCTAssertEqual(favorites.slugs, ["eldad", "gosen"])
        XCTAssertEqual(favorites.members, ["eldad", "gosen"])
    }

    // MARK: - Stations

    func test_the_stations_come_in_the_listeners_order() {
        let favorites = FavoriteList(["predic", "eldad"])

        XCTAssertEqual(
            favorites.stations(among: catalog("eldad", "gosen", "predic"))
                .map(\.slug),
            ["predic", "eldad"]
        )
    }

    func test_a_favorite_missing_from_the_catalog_is_skipped() {
        let favorites = FavoriteList(["gone", "eldad"])

        XCTAssertEqual(
            favorites.stations(among: catalog("eldad")).map(\.slug),
            ["eldad"]
        )
    }

    // MARK: - An old save

    func test_an_old_save_takes_the_order_it_was_shown_in() {
        // A set saved them in no particular order; "Favorite" showed them
        // in catalog order.
        let saved = FavoriteList(["predic", "eldad", "gosen"])

        let arranged = saved.arranged(asShown: [
            "aripi", "eldad", "gosen", "philadelphia", "predic",
        ])

        XCTAssertEqual(arranged.slugs, ["eldad", "gosen", "predic"])
    }

    func test_a_favorite_the_catalog_no_longer_lists_keeps_its_place() {
        let saved = FavoriteList(["predic", "gone", "eldad"])

        let arranged = saved.arranged(asShown: ["eldad", "predic"])

        XCTAssertEqual(arranged.slugs, ["eldad", "gone", "predic"])
    }

    func test_arranging_ignores_repeats_in_the_shown_order() {
        let saved = FavoriteList(["predic", "eldad"])

        let arranged = saved.arranged(asShown: ["eldad", "eldad", "predic"])

        XCTAssertEqual(arranged.slugs, ["eldad", "predic"])
    }
}
