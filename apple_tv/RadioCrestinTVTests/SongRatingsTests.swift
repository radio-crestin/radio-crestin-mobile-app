import XCTest
@testable import RadioCrestinTV

/// Apreciază and Nu îmi place: the rating a press leaves, the review it
/// sends (the phone's `likeSong` / `dislikeSong`), and the ratings kept
/// across launches, by song id, or by title and artist for a song shown
/// without one. Reviews go to `ReviewStubProtocol`, never to the API.
@MainActor
final class SongRatingsTests: XCTestCase {

    private var suite = ""
    private var defaults = UserDefaults.standard
    private let failures = ReportedFailures()

    override func setUp() async throws {
        suite = "SongRatingsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        ReviewStubProtocol.reset()
    }

    /// The ratings as a launch finds them on this test's defaults.
    private func launch() -> SongRatings {
        SongRatings(
            defaults: defaults,
            reviews: ReviewStubProtocol.service(reportFailure: failures.record)
        )
    }

    private func station(
        id: Int = 12,
        title: String = "Radio Ekklesia",
        songId: Int = 990003,
        song: String? = "Har",
        artist: String? = "Cor"
    ) -> Station {
        Station(
            id: id,
            slug: "s\(id)",
            title: title,
            order: 0,
            thumbnailUrl: nil,
            totalListeners: nil,
            stationStreams: [],
            uptime: nil,
            nowPlaying: song.map {
                NowPlaying(
                    id: 1,
                    timestamp: nil,
                    song: Song(
                        id: songId, name: $0, thumbnailUrl: nil,
                        artist: artist.map {
                            Artist(id: 0, name: $0, thumbnailUrl: nil)
                        }
                    )
                )
            },
            reviewsStats: nil,
            stationType: nil,
            playlistItems: nil,
            hlsDvrStreamUrl: nil
        )
    }

    private var sentBodies: [[String: Any]] {
        ReviewStubProtocol.received.map(\.body)
    }

    /// The endpoints asked, after the API base.
    private var sentPaths: [String] {
        ReviewStubProtocol.received.map {
            String($0.url.absoluteString.dropFirst(ReviewStubProtocol.baseURL.count))
        }
    }

    // MARK: - Pressing

    func test_a_like_is_shown_at_once_and_sent_as_five_stars() async {
        let ratings = launch()

        let sending = ratings.press(.liked, for: station())
        XCTAssertEqual(ratings.rating(of: station()), .liked)
        await sending.value

        XCTAssertEqual(sentPaths, ["/reviews/"])
        let body = sentBodies[0]
        XCTAssertEqual(body["stars"] as? Int, 5)
        XCTAssertEqual(body["message"] as? String, "I like: Har - Cor")
        XCTAssertEqual(body["station_id"] as? Int, 12)
        XCTAssertEqual(body["song_id"] as? Int, 990003)
        XCTAssertEqual(body["user_identifier"] as? String, "test-device")
    }

    func test_a_dislike_is_sent_as_one_star_in_the_phones_words() async {
        let ratings = launch()

        await ratings.press(.disliked, for: station()).value

        XCTAssertEqual(ratings.rating(of: station()), .disliked)
        XCTAssertEqual(sentBodies[0]["stars"] as? Int, 1)
        XCTAssertEqual(
            sentBodies[0]["message"] as? String, "I don't like: Har - Cor"
        )
    }

    func test_pressing_the_rating_that_is_on_takes_it_back() async {
        let ratings = launch()
        await ratings.press(.liked, for: station()).value

        await ratings.press(.liked, for: station()).value

        XCTAssertNil(ratings.rating(of: station()))
        XCTAssertEqual(sentPaths, ["/reviews/", "/reviews/delete/"])
        XCTAssertTrue(failures.all.isEmpty)
        XCTAssertEqual(sentBodies[1].count, 2)
        XCTAssertEqual(sentBodies[1]["station_id"] as? Int, 12)
        XCTAssertEqual(sentBodies[1]["song_id"] as? Int, 990003)
    }

    /// The other button replaces the rating: the API keeps one review per
    /// listener, station and song, so the new one is all it needs.
    func test_the_other_button_replaces_the_rating() async {
        let ratings = launch()
        await ratings.press(.liked, for: station()).value

        await ratings.press(.disliked, for: station()).value

        XCTAssertEqual(ratings.rating(of: station()), .disliked)
        XCTAssertEqual(sentPaths, ["/reviews/", "/reviews/"])
        XCTAssertEqual(sentBodies[1]["stars"] as? Int, 1)
        XCTAssertEqual(ratings.entries.count, 1)
    }

    func test_each_song_has_its_own_rating() async {
        let ratings = launch()

        await ratings.press(.liked, for: station(songId: 1, song: "Unu")).value

        XCTAssertEqual(ratings.rating(of: station(songId: 1, song: "Unu")), .liked)
        XCTAssertNil(ratings.rating(of: station(songId: 2, song: "Doi")))
    }

    /// The same song on another station shows the rating, as on the phone
    /// (ratings are per song); taking it back there deletes the review
    /// the first station got.
    func test_a_song_rated_on_one_station_shows_it_on_another() async {
        let ratings = launch()
        await ratings.press(.liked, for: station(id: 12)).value

        XCTAssertEqual(ratings.rating(of: station(id: 40)), .liked)
        await ratings.press(.liked, for: station(id: 40)).value

        XCTAssertEqual(sentBodies[1]["station_id"] as? Int, 12)
        XCTAssertNil(ratings.rating(of: station(id: 12)))
    }

    /// Review, round 7: the other button where another station played the
    /// song left the first station's review on the API, which keeps one
    /// per station and song, while the device showed only the new rating.
    func test_switching_on_another_station_takes_back_the_first_review() async {
        let ratings = launch()
        await ratings.press(.liked, for: station(id: 12)).value

        await ratings.press(.disliked, for: station(id: 40)).value

        XCTAssertEqual(ratings.rating(of: station(id: 12)), .disliked)
        XCTAssertEqual(sentPaths, ["/reviews/", "/reviews/delete/", "/reviews/"])
        XCTAssertEqual(sentBodies[1]["station_id"] as? Int, 12)
        XCTAssertEqual(sentBodies[1]["song_id"] as? Int, 990003)
        XCTAssertEqual(sentBodies[2]["station_id"] as? Int, 40)
        XCTAssertEqual(sentBodies[2]["stars"] as? Int, 1)
    }

    // MARK: - Kept on the device

    func test_ratings_are_kept_across_launches() async {
        await launch().press(.liked, for: station(songId: 5)).value
        await launch().press(.disliked, for: station(songId: 6, song: "Alt")).value

        let relaunched = launch()

        XCTAssertEqual(relaunched.rating(of: station(songId: 5)), .liked)
        XCTAssertEqual(
            relaunched.rating(of: station(songId: 6, song: "Alt")), .disliked
        )
    }

    func test_a_rating_taken_back_stays_gone_after_a_relaunch() async {
        await launch().press(.liked, for: station()).value
        await launch().press(.liked, for: station()).value

        XCTAssertNil(launch().rating(of: station()))
        XCTAssertTrue(launch().entries.isEmpty)
    }

    func test_only_the_latest_ratings_are_kept() async {
        let ratings = launch()
        var sendings: [Task<Void, Never>] = []
        for songId in 1...(SongRatings.capacity + 1) {
            sendings.append(ratings.press(
                .liked, for: station(songId: songId, song: "S\(songId)")
            ))
        }
        for sending in sendings { await sending.value }

        let relaunched = launch()
        XCTAssertEqual(relaunched.entries.count, SongRatings.capacity)
        XCTAssertNil(relaunched.rating(of: station(songId: 1, song: "S1")))
        XCTAssertEqual(relaunched.rating(of: station(songId: 2, song: "S2")), .liked)
    }

    func test_a_failed_review_keeps_the_rating_and_is_reported() async {
        ReviewStubProtocol.serve(status: 503, body: "")
        let ratings = launch()

        await ratings.press(.liked, for: station()).value

        XCTAssertEqual(ratings.rating(of: station()), .liked)
        XCTAssertEqual(failures.all.count, 1)
        XCTAssertEqual(failures.all.first?.context, "review_submit")
    }

    // MARK: - Songs without an id

    /// Review, round 6: a song shown without its id was sent as a review
    /// without a song, which is the listener's review of the station: a
    /// like of the song replaced it, and taking the like back deleted it.
    /// Such a song is rated on the device only, kept by title and artist,
    /// ignoring case and outer spaces.
    func test_a_song_without_an_id_is_rated_on_the_device_only() async {
        let ratings = launch()

        await ratings.press(.liked, for: station(songId: 0)).value

        XCTAssertTrue(ReviewStubProtocol.received.isEmpty)
        XCTAssertEqual(
            ratings.rating(of: station(songId: 0, song: " har ", artist: "COR")),
            .liked
        )
        XCTAssertNil(ratings.rating(of: station(songId: 0, artist: "Altul")))
        XCTAssertEqual(ratings.entries.first?.key, "title:har\u{1F}cor")
    }

    /// The rating given without an id holds once the payload brings the
    /// id; taking it back sends nothing, as nothing was sent.
    func test_a_rating_given_without_an_id_holds_once_the_id_arrives() async {
        let ratings = launch()
        await ratings.press(.liked, for: station(songId: 0)).value

        XCTAssertEqual(ratings.rating(of: station(songId: 77)), .liked)
        await ratings.press(.liked, for: station(songId: 77)).value

        XCTAssertNil(ratings.rating(of: station(songId: 77)))
        XCTAssertNil(ratings.rating(of: station(songId: 0)))
        XCTAssertTrue(ReviewStubProtocol.received.isEmpty)
    }

    func test_the_other_rating_of_a_song_rated_without_its_id_is_sent_with_it() async {
        let ratings = launch()
        await ratings.press(.liked, for: station(songId: 0)).value

        await ratings.press(.disliked, for: station(songId: 77)).value

        XCTAssertEqual(ratings.rating(of: station(songId: 77)), .disliked)
        XCTAssertEqual(sentPaths, ["/reviews/"])
        XCTAssertEqual(sentBodies[0]["song_id"] as? Int, 77)
        XCTAssertEqual(ratings.entries.count, 1)
    }

    /// Review, round 6: a song rated with its id showed unrated while it
    /// showed without one, and its review could not be taken back.
    func test_a_song_rated_with_its_id_keeps_its_rating_without_it() async {
        let ratings = launch()
        await ratings.press(.liked, for: station(songId: 77)).value

        XCTAssertEqual(ratings.rating(of: station(songId: 0)), .liked)
        await ratings.press(.liked, for: station(songId: 0)).value

        XCTAssertNil(ratings.rating(of: station(songId: 0)))
        XCTAssertNil(ratings.rating(of: station(songId: 77)))
        XCTAssertEqual(sentPaths, ["/reviews/", "/reviews/delete/"])
        XCTAssertEqual(sentBodies[1]["song_id"] as? Int, 77)
    }

    func test_the_other_rating_of_a_song_shown_without_its_id_names_the_id() async {
        let ratings = launch()
        await ratings.press(.liked, for: station(songId: 77)).value

        await ratings.press(.disliked, for: station(songId: 0)).value

        XCTAssertEqual(ratings.rating(of: station(songId: 77)), .disliked)
        XCTAssertEqual(sentBodies[1]["song_id"] as? Int, 77)
        XCTAssertEqual(sentBodies[1]["stars"] as? Int, 1)
        XCTAssertEqual(ratings.entries.count, 1)
    }

    // MARK: - Order

    /// Review, round 6: each press was sent at once, so a quick take-back
    /// could reach the API before the review it takes back, which stayed.
    func test_a_quick_take_back_reaches_the_api_after_the_review() async {
        ReviewStubProtocol.holdAnswers()
        let ratings = launch()

        ratings.press(.liked, for: station())
        let takeBack = ratings.press(.liked, for: station())
        let reviewSent = await eventually { self.sentPaths == ["/reviews/"] }
        await letQueuedWorkRun()

        XCTAssertTrue(reviewSent)
        XCTAssertEqual(sentPaths, ["/reviews/"], "the take-back waits")
        ReviewStubProtocol.releaseAnswers()
        await takeBack.value
        XCTAssertEqual(sentPaths, ["/reviews/", "/reviews/delete/"])
    }

    /// A song rated with its id is not rated under another id because the
    /// titles match: two recordings, or two programmes called "Live".
    func test_a_rating_by_id_does_not_spread_to_another_id() async {
        let ratings = launch()

        await ratings.press(.liked, for: station(songId: 5)).value

        XCTAssertNil(ratings.rating(of: station(songId: 6)))
    }

    // MARK: - Stations without a song

    /// Without a song the station itself is rated, under its name, as the
    /// phone's `_buildSongInfo` falls back to it.
    func test_a_station_without_a_song_is_rated_as_the_station() async {
        let ratings = launch()

        await ratings.press(.liked, for: station(song: nil)).value

        XCTAssertEqual(ratings.rating(of: station(song: nil)), .liked)
        XCTAssertNil(ratings.rating(of: station(id: 40, song: nil)))
        XCTAssertEqual(
            sentBodies[0]["message"] as? String, "I like: Radio Ekklesia"
        )
        XCTAssertNil(sentBodies[0]["song_id"])

        await ratings.press(.liked, for: station(song: nil)).value
        XCTAssertEqual(sentBodies[1].count, 1)
        XCTAssertEqual(sentBodies[1]["station_id"] as? Int, 12)
    }

    // MARK: - Pure rules

    func test_the_message_names_the_song_as_the_phone_does() {
        XCTAssertEqual(RatedSong(station: station()).info, "Har - Cor")
        XCTAssertEqual(RatedSong(station: station(artist: nil)).info, "Har")
        XCTAssertEqual(RatedSong(station: station(song: nil)).info, "Radio Ekklesia")
    }

    func test_pressing_a_rating_that_is_off_gives_it() {
        let song = RatedSong(station: station())

        let press = SongRatingPress.pressing(.liked, current: nil, song: song)

        XCTAssertEqual(press.rating, .liked)
        XCTAssertEqual(press.requests, [.submit(
            stationId: 12, stars: 5, message: "I like: Har - Cor", songId: 990003
        )])
    }

    func test_pressing_the_other_rating_switches_to_it() {
        let song = RatedSong(station: station())
        let liked = SongRatingEntry(
            key: song.key, rating: .liked, stationId: 12, songId: 990003
        )

        let press = SongRatingPress.pressing(.disliked, current: liked, song: song)

        XCTAssertEqual(press.rating, .disliked)
        XCTAssertEqual(press.requests, [.submit(
            stationId: 12, stars: 1, message: "I don't like: Har - Cor",
            songId: 990003
        )])
    }

    func test_switching_where_another_station_plays_the_song_deletes_its_review_first() {
        let song = RatedSong(station: station(id: 40, songId: 77))
        let liked = SongRatingEntry(
            key: song.key, rating: .liked, stationId: 12, songId: 77
        )

        let press = SongRatingPress.pressing(.disliked, current: liked, song: song)

        XCTAssertEqual(press.rating, .disliked)
        XCTAssertEqual(press.requests, [
            .delete(stationId: 12, songId: 77),
            .submit(
                stationId: 40, stars: 1, message: "I don't like: Har - Cor",
                songId: 77
            ),
        ])
    }

    func test_pressing_the_rating_that_is_on_deletes_the_review_it_sent() {
        let song = RatedSong(station: station(id: 40, songId: 8))
        let disliked = SongRatingEntry(
            key: song.key, rating: .disliked, stationId: 12, songId: 0
        )

        let press = SongRatingPress.pressing(.disliked, current: disliked, song: song)

        XCTAssertNil(press.rating)
        XCTAssertEqual(press.requests, [.delete(stationId: 12, songId: nil)])
    }
}
