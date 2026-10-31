import XCTest
@testable import RadioCrestinTV

/// What tvOS Now Playing / Control Center shows for the current station.
final class NowPlayingSnapshotTests: XCTestCase {

    private func station(
        song: String? = nil,
        artist: String? = nil,
        stationType: String? = nil
    ) -> Station {
        Station(
            id: 1,
            slug: "eldad",
            title: "Eldad",
            order: 0,
            thumbnailUrl: "https://img/logo.png",
            totalListeners: nil,
            stationStreams: [],
            uptime: nil,
            nowPlaying: song.map {
                NowPlaying(
                    id: 1,
                    timestamp: nil,
                    song: Song(
                        id: 1, name: $0, thumbnailUrl: nil,
                        artist: artist.map {
                            Artist(id: 1, name: $0, thumbnailUrl: nil)
                        }
                    )
                )
            },
            reviewsStats: nil,
            stationType: stationType,
            playlistItems: nil,
            hlsDvrStreamUrl: nil
        )
    }

    func test_nothing_shows_without_a_station_or_while_idle() {
        XCTAssertNil(NowPlayingSnapshot(station: nil, state: .playing("Eldad")))
        XCTAssertNil(NowPlayingSnapshot(station: station(), state: .idle))
    }

    /// Connecting counts as playing so the system offers Pause, which
    /// cancels the connection like the on-screen button; Play would have
    /// nothing to start.
    func test_connecting_and_playing_show_as_playing() {
        let connecting = NowPlayingSnapshot(
            station: station(), state: .connecting("Eldad")
        )
        let playing = NowPlayingSnapshot(
            station: station(), state: .playing("Eldad")
        )
        XCTAssertEqual(connecting?.isPlaying, true)
        XCTAssertEqual(playing?.isPlaying, true)
    }

    func test_paused_and_failed_show_as_stopped() {
        let paused = NowPlayingSnapshot(
            station: station(), state: .paused("Eldad")
        )
        let failed = NowPlayingSnapshot(
            station: station(), state: .failed("Nu s-a putut conecta la post")
        )
        XCTAssertEqual(paused?.isPlaying, false)
        XCTAssertEqual(failed?.isPlaying, false)
    }

    func test_a_radio_song_shows_with_the_station_as_album() throws {
        let snapshot = try XCTUnwrap(NowPlayingSnapshot(
            station: station(song: "Har", artist: "Cor"),
            state: .playing("Eldad")
        ))
        XCTAssertEqual(snapshot.title, "Har")
        XCTAssertEqual(snapshot.artist, "Cor")
        XCTAssertEqual(snapshot.album, "Eldad")
        XCTAssertTrue(snapshot.isLiveStream)
    }

    func test_without_a_song_the_station_is_the_title() throws {
        let snapshot = try XCTUnwrap(NowPlayingSnapshot(
            station: station(), state: .playing("Eldad")
        ))
        XCTAssertEqual(snapshot.title, "Eldad")
        XCTAssertNil(snapshot.artist)
        XCTAssertNil(snapshot.album)
    }

    func test_a_playlist_is_not_a_live_stream() throws {
        let snapshot = try XCTUnwrap(NowPlayingSnapshot(
            station: station(song: "Har", stationType: "playlist"),
            state: .playing("Eldad")
        ))
        XCTAssertEqual(snapshot.title, "Eldad")
        XCTAssertFalse(snapshot.isLiveStream)
    }
}
