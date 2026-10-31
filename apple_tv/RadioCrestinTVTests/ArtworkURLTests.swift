import XCTest
@testable import RadioCrestinTV

/// CDN URLs asked for at the size of the slot that shows them.
final class ArtworkURLTests: XCTestCase {

    private let logo = URL(string:
        "https://cdn.radiocrestin.ro/?url=https%3A%2F%2Ffsn1.your-objectstorage.com"
        + "%2Fpublic%2Fstations%2Frve-cluj.png&sig=4f2a9c&w=250&f=webp"
        + "&max_age=2592000"
    )!

    func test_the_width_follows_the_slot_rounded_up_to_a_step() {
        // A grid card: 257.5 pt at 2x, lifted 12% by focus.
        let sized = ArtworkURL.sized(logo, pixels: 257.5 * 2 * 1.12)
        XCTAssertEqual(
            sized.absoluteString,
            logo.absoluteString.replacingOccurrences(of: "w=250", with: "w=600")
        )
    }

    func test_a_width_already_on_a_step_stays() {
        let sized = ArtworkURL.sized(logo, pixels: 1000)
        XCTAssertTrue(sized.absoluteString.contains("&w=1000&"))
    }

    /// The signature covers the source URL as encoded: it must go back to
    /// the CDN exactly as the API gave it.
    func test_only_the_width_changes() {
        let sized = ArtworkURL.sized(logo, pixels: 920)
        let before = URLComponents(url: logo, resolvingAgainstBaseURL: false)?
            .percentEncodedQueryItems ?? []
        let after = URLComponents(url: sized, resolvingAgainstBaseURL: false)?
            .percentEncodedQueryItems ?? []
        XCTAssertEqual(after.map(\.name), before.map(\.name))
        for (old, new) in zip(before, after) where old.name != "w" {
            XCTAssertEqual(new.value, old.value, old.name)
        }
        XCTAssertEqual(after.first { $0.name == "w" }?.value, "1000")
    }

    func test_other_hosts_and_urls_without_a_width_are_left_alone() {
        let other = URL(string: "https://img.example/logo.png?w=250")!
        let unsized = URL(string: "https://cdn.radiocrestin.ro/?url=x&sig=y")!
        XCTAssertEqual(ArtworkURL.sized(other, pixels: 920), other)
        XCTAssertEqual(ArtworkURL.sized(unsized, pixels: 920), unsized)
    }

    /// A slot not laid out yet has no width to ask for.
    func test_an_empty_slot_keeps_the_url() {
        XCTAssertEqual(ArtworkURL.sized(logo, pixels: 0), logo)
    }

    func test_a_list_is_sized_in_points_at_the_screen_scale() {
        let sized = ArtworkURL.sized([logo, logo], points: 460, scale: 2)
        XCTAssertEqual(sized.count, 2)
        XCTAssertTrue(sized.allSatisfy { $0.absoluteString.contains("&w=1000&") })
    }

    /// The system's Now Playing keeps its artwork as a 768 px picture: the
    /// song cover and the logo are asked for at that width, rounded up to
    /// the CDN step, rather than at the API's 250 px.
    func test_the_system_now_playing_asks_for_its_own_size() throws {
        let cover = logo.absoluteString
            .replacingOccurrences(of: "rve-cluj.png", with: "cover.jpg")
        let station = Station(
            id: 1,
            slug: "rve-cluj",
            title: "RVE Cluj",
            order: 0,
            thumbnailUrl: logo.absoluteString,
            totalListeners: nil,
            stationStreams: [],
            uptime: nil,
            nowPlaying: NowPlaying(
                id: 1,
                timestamp: nil,
                song: Song(id: 1, name: "Har", thumbnailUrl: cover, artist: nil)
            ),
            reviewsStats: nil,
            stationType: nil,
            playlistItems: nil,
            hlsDvrStreamUrl: nil
        )

        let snapshot = try XCTUnwrap(
            NowPlayingSnapshot(station: station, state: .playing("RVE Cluj"))
        )

        let expected = [cover, logo.absoluteString].map {
            URL(string: $0.replacingOccurrences(of: "w=250", with: "w=800"))!
        }
        XCTAssertEqual(snapshot.artworkURLs, expected)
    }
}
