import XCTest
@testable import RadioCrestinTV

final class StationModelTests: XCTestCase {

    func makeStation(
        id: Int = 1,
        slug: String = "radio-x",
        title: String = "Radio X",
        order: Int = 0,
        thumbnailUrl: String? = "https://example.com/logo.png",
        totalListeners: Int? = 10,
        streams: [StationStream] = [
            StationStream(order: 0, type: "MP3", streamUrl: "https://x/a.mp3"),
        ],
        uptime: Uptime? = Uptime(isUp: true, timestamp: nil),
        nowPlaying: NowPlaying? = nil,
        reviewsStats: ReviewsStats? = nil,
        stationType: String? = nil,
        playlistItems: [PlaylistItem]? = nil,
        hlsDvrStreamUrl: String? = nil
    ) -> Station {
        Station(
            id: id, slug: slug, title: title, order: order,
            thumbnailUrl: thumbnailUrl,
            totalListeners: totalListeners,
            stationStreams: streams,
            uptime: uptime,
            nowPlaying: nowPlaying,
            reviewsStats: reviewsStats,
            stationType: stationType,
            playlistItems: playlistItems,
            hlsDvrStreamUrl: hlsDvrStreamUrl
        )
    }

    // MARK: - Codable

    func test_decodes_from_canonical_API_payload() throws {
        let json = """
        {
          "id": 1, "slug": "radio-emanuel", "title": "Radio Emanuel", "order": 5,
          "thumbnail_url": "https://e.com/logo.png",
          "total_listeners": 42,
          "station_streams": [
            { "order": 0, "type": "HLS", "stream_url": "https://e/h.m3u8" },
            { "order": 1, "type": "MP3", "stream_url": "https://e/a.mp3" }
          ],
          "uptime": { "is_up": true, "timestamp": "2026-04-15T10:00:00Z" },
          "now_playing": null,
          "reviews_stats": { "average_rating": 4.5, "number_of_reviews": 12 }
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Station.self, from: json)
        XCTAssertEqual(s.id, 1)
        XCTAssertEqual(s.slug, "radio-emanuel")
        XCTAssertEqual(s.totalListeners, 42)
        XCTAssertEqual(s.stationStreams.count, 2)
        XCTAssertEqual(s.uptime?.isUp, true)
        XCTAssertEqual(s.reviewCount, 12)
        XCTAssertEqual(s.averageRating, 4.5, accuracy: 0.001)
    }

    // MARK: - DVR field (hls_dvr_stream_url) decoding
    //
    // The field is decoded purely to future-proof the model — DVR/timeshift
    // playback is intentionally NOT implemented on tvOS yet, so nothing
    // reads it. These tests only pin the wire mapping so a future feature
    // can rely on it without a migration.

    func test_dvr_url_decodes_when_present() throws {
        let json = """
        {
          "id": 1, "slug": "r", "title": "R", "order": 0,
          "station_streams": [],
          "hls_dvr_stream_url": "https://live.radiocrestin.ro/hls/r/dvr.m3u8"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Station.self, from: json)
        XCTAssertEqual(s.hlsDvrStreamUrl,
                       "https://live.radiocrestin.ro/hls/r/dvr.m3u8")
    }

    func test_dvr_url_absent_is_nil() throws {
        // Production omits the field entirely today.
        let json = """
        {
          "id": 1, "slug": "r", "title": "R", "order": 0,
          "station_streams": []
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Station.self, from: json)
        XCTAssertNil(s.hlsDvrStreamUrl)
    }

    func test_dvr_url_explicit_null_is_nil() throws {
        let json = """
        {
          "id": 1, "slug": "r", "title": "R", "order": 0,
          "station_streams": [],
          "hls_dvr_stream_url": null
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Station.self, from: json)
        XCTAssertNil(s.hlsDvrStreamUrl)
    }

    // MARK: - Station kind + playlist decoding

    func test_stationType_missing_defaults_to_radio() throws {
        let json = """
        {
          "id": 1, "slug": "r", "title": "R", "order": 0,
          "station_streams": []
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Station.self, from: json)
        XCTAssertNil(s.stationType)
        XCTAssertEqual(s.kind, .radio)
        XCTAssertFalse(s.hasOnlyUnplayableItems)
        XCTAssertTrue(s.playableItems.isEmpty)
    }

    func test_stationType_null_defaults_to_radio() {
        XCTAssertEqual(makeStation(stationType: nil).kind, .radio)
    }

    func test_stationType_parsed_case_insensitively() {
        XCTAssertEqual(makeStation(stationType: "TV").kind, .tv)
        XCTAssertEqual(makeStation(stationType: "Tv").kind, .tv)
        XCTAssertEqual(makeStation(stationType: "PLAYLIST").kind, .playlist)
        XCTAssertEqual(makeStation(stationType: "radio").kind, .radio)
        XCTAssertEqual(makeStation(stationType: "wat").kind, .radio)
    }

    func test_playlist_items_decode_preserving_wire_order() throws {
        // The backend serves playlist items newest-first (descending
        // playlist_item_order). The wire order is authoritative: the
        // first array element plays first, so playableItems must NOT
        // re-sort by the `order` field.
        let json = """
        {
          "id": 7, "slug": "p", "title": "P", "order": 0,
          "station_streams": [],
          "station_type": "playlist",
          "playlist_items": [
            { "id": 2, "order": 1, "type": "video",
              "url": "https://x/b.mp4", "title": "B",
              "thumbnail_url": "https://x/b.png", "duration_seconds": 120 },
            { "id": 1, "order": 0, "type": "audio",
              "url": "https://x/a.mp3", "title": "A" }
          ]
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Station.self, from: json)
        XCTAssertEqual(s.kind, .playlist)
        XCTAssertEqual(s.playlistItems?.count, 2)
        // Wire order preserved — id 2 (order 1) stays first even though
        // its `order` field is higher.
        XCTAssertEqual(s.playableItems.map(\.id), [2, 1])
        let first = s.playableItems[0]
        XCTAssertEqual(first.title, "B")
        XCTAssertTrue(first.isVideo)
        XCTAssertEqual(first.durationSeconds, 120)
        XCTAssertEqual(first.thumbnailUrl, "https://x/b.png")
        let second = s.playableItems[1]
        XCTAssertEqual(second.title, "A")
        XCTAssertTrue(second.isAudio)
        XCTAssertNil(second.durationSeconds)
    }

    func test_playableItems_allowlists_audio_and_video_only() {
        let items = [
            PlaylistItem(id: 1, order: 0, type: "audio", url: "a",
                         title: "A", thumbnailUrl: nil, durationSeconds: nil),
            PlaylistItem(id: 2, order: 1, type: "youtube", url: "yt",
                         title: "YT", thumbnailUrl: nil, durationSeconds: nil),
            PlaylistItem(id: 3, order: 2, type: "video", url: "v",
                         title: "V", thumbnailUrl: nil, durationSeconds: nil),
            PlaylistItem(id: 4, order: 3, type: "youtube_playlist", url: "ytp",
                         title: "YTP", thumbnailUrl: nil, durationSeconds: nil),
            PlaylistItem(id: 5, order: 4, type: "hologram", url: "h",
                         title: "Future", thumbnailUrl: nil, durationSeconds: nil),
        ]
        let s = makeStation(stationType: "playlist", playlistItems: items)
        // youtube, youtube_playlist, and unknown types all excluded.
        XCTAssertEqual(s.playableItems.map(\.id), [1, 3])
        XCTAssertFalse(s.hasOnlyUnplayableItems)
    }

    func test_isPlayable_is_case_insensitive_allowlist() {
        func item(_ type: String) -> PlaylistItem {
            PlaylistItem(id: 1, order: 0, type: type, url: "u",
                         title: "T", thumbnailUrl: nil, durationSeconds: nil)
        }
        XCTAssertTrue(item("Audio").isPlayable)
        XCTAssertTrue(item("VIDEO").isPlayable)
        XCTAssertFalse(item("youtube").isPlayable)
        XCTAssertFalse(item("YouTube_Playlist").isPlayable)
        XCTAssertFalse(item("").isPlayable)
    }

    func test_hasOnlyUnplayableItems_true_when_nothing_playable() {
        let items = [
            PlaylistItem(id: 1, order: 0, type: "youtube", url: "y1",
                         title: "1", thumbnailUrl: nil, durationSeconds: nil),
            PlaylistItem(id: 2, order: 1, type: "YouTube_Playlist", url: "y2",
                         title: "2", thumbnailUrl: nil, durationSeconds: nil),
            PlaylistItem(id: 3, order: 2, type: "vr_scene", url: "y3",
                         title: "3", thumbnailUrl: nil, durationSeconds: nil),
        ]
        let s = makeStation(stationType: "playlist", playlistItems: items)
        XCTAssertTrue(s.hasOnlyUnplayableItems)
        XCTAssertTrue(s.playableItems.isEmpty)
    }

    func test_hasOnlyUnplayableItems_false_for_non_playlist() {
        let items = [
            PlaylistItem(id: 1, order: 0, type: "youtube", url: "y1",
                         title: "1", thumbnailUrl: nil, durationSeconds: nil),
        ]
        // Even if no item is playable, a radio-kind station never shows
        // the playlist "nothing playable" message.
        let s = makeStation(stationType: "radio", playlistItems: items)
        XCTAssertFalse(s.hasOnlyUnplayableItems)
    }

    // MARK: - Computed properties

    func test_isUp_defaults_to_true_when_uptime_missing() {
        let s = makeStation(uptime: nil)
        XCTAssertTrue(s.isUp)
    }

    func test_isUp_reflects_uptime_flag() {
        XCTAssertFalse(makeStation(uptime: Uptime(isUp: false, timestamp: nil)).isUp)
    }

    func test_missing_uptime_is_unknown_not_down() {
        // A station with backend check_uptime=false ships no uptime record.
        // That's "unknown", never "down": it must stay playable so no
        // unavailable state is rendered for it.
        XCTAssertTrue(makeStation(uptime: nil).isUp)
        XCTAssertTrue(makeStation(uptime: nil, stationType: "tv").isUp)
        XCTAssertTrue(makeStation(uptime: nil, stationType: "playlist").isUp)
    }

    // MARK: - cardSubtitle (grid second line)

    func test_cardSubtitle_radio_uses_current_song() {
        let np = NowPlaying(
            id: 1, timestamp: nil,
            song: Song(id: 1, name: "Osana", thumbnailUrl: nil, artist: nil)
        )
        XCTAssertEqual(makeStation(nowPlaying: np).cardSubtitle, "Osana")
    }

    func test_cardSubtitle_radio_empty_when_no_song() {
        // Radio with no now_playing shows only its title — an empty second
        // line is the intended (unchanged) behavior for radio.
        XCTAssertEqual(makeStation(nowPlaying: nil).cardSubtitle, "")
    }

    func test_cardSubtitle_tv_is_live_label() {
        XCTAssertEqual(makeStation(stationType: "tv").cardSubtitle,
                       "Transmisiune live")
    }

    func test_cardSubtitle_playlist_counts_playable_items() {
        let items = [
            PlaylistItem(id: 1, order: 0, type: "audio", url: "a",
                         title: "A", thumbnailUrl: nil, durationSeconds: nil),
            PlaylistItem(id: 2, order: 1, type: "video", url: "v",
                         title: "V", thumbnailUrl: nil, durationSeconds: nil),
            PlaylistItem(id: 3, order: 2, type: "youtube", url: "y",
                         title: "Y", thumbnailUrl: nil, durationSeconds: nil),
        ]
        // youtube is unplayable → 2 counted.
        let s = makeStation(stationType: "playlist", playlistItems: items)
        XCTAssertEqual(s.cardSubtitle, "Listă de redare · 2 piese")
    }

    func test_cardSubtitle_playlist_singular_item() {
        let items = [
            PlaylistItem(id: 1, order: 0, type: "audio", url: "a",
                         title: "A", thumbnailUrl: nil, durationSeconds: nil),
        ]
        let s = makeStation(stationType: "playlist", playlistItems: items)
        XCTAssertEqual(s.cardSubtitle, "Listă de redare · o piesă")
    }

    func test_cardSubtitle_playlist_label_when_nothing_countable() {
        // YouTube-only, empty, or missing lists still get a meaningful
        // label — never an empty second line.
        let youtubeOnly = [
            PlaylistItem(id: 1, order: 0, type: "youtube", url: "y",
                         title: "Y", thumbnailUrl: nil, durationSeconds: nil),
        ]
        XCTAssertEqual(
            makeStation(stationType: "playlist", playlistItems: youtubeOnly).cardSubtitle,
            "Listă de redare"
        )
        XCTAssertEqual(
            makeStation(stationType: "playlist", playlistItems: nil).cardSubtitle,
            "Listă de redare"
        )
    }

    func test_orderedStreams_sorts_by_order() {
        let s = makeStation(streams: [
            StationStream(order: 2, type: "MP3", streamUrl: "c"),
            StationStream(order: 0, type: "HLS", streamUrl: "a"),
            StationStream(order: 1, type: "MP3", streamUrl: "b"),
        ])
        XCTAssertEqual(s.orderedStreams.map(\.streamUrl), ["a", "b", "c"])
    }

    func test_primaryStreamIsHls_uses_lowest_order_stream() {
        let hlsFirst = makeStation(streams: [
            StationStream(order: 0, type: "HLS", streamUrl: "a"),
            StationStream(order: 1, type: "MP3", streamUrl: "b"),
        ])
        XCTAssertTrue(hlsFirst.primaryStreamIsHls)

        let mp3First = makeStation(streams: [
            StationStream(order: 1, type: "HLS", streamUrl: "a"),
            StationStream(order: 0, type: "MP3", streamUrl: "b"),
        ])
        XCTAssertFalse(mp3First.primaryStreamIsHls)
    }

    func test_song_helpers_return_empty_when_no_now_playing() {
        let s = makeStation(nowPlaying: nil)
        XCTAssertEqual(s.songTitle, "")
        XCTAssertEqual(s.songArtist, "")
        XCTAssertNil(s.songThumbnailUrl)
    }

    func test_song_thumbnail_falls_back_to_artist_thumbnail() {
        let np = NowPlaying(
            id: 1, timestamp: nil,
            song: Song(
                id: 9, name: "Hymn",
                thumbnailUrl: nil,
                artist: Artist(id: 1, name: "Choir",
                               thumbnailUrl: "https://x/artist.png")
            )
        )
        let s = makeStation(nowPlaying: np)
        XCTAssertEqual(s.songThumbnailUrl, "https://x/artist.png")
    }

    func test_displayThumbnailURLs_drops_invalid_and_nil() {
        let s = makeStation(thumbnailUrl: "https://x/logo.png")
        let urls = s.displayThumbnailURLs
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.absoluteString, "https://x/logo.png")
    }

    func test_reviewScore_is_average_times_count() {
        let s = makeStation(reviewsStats:
            ReviewsStats(averageRating: 4.0, numberOfReviews: 5))
        XCTAssertEqual(s.reviewScore, 20.0, accuracy: 0.001)
    }

    func test_reviewScore_zero_when_no_reviews() {
        let s = makeStation(reviewsStats: nil)
        XCTAssertEqual(s.reviewScore, 0.0)
    }

    // MARK: - merging(_:liveListeners:)

    // The merging() helper takes a StationMetadata decoded from the
    // /stations-metadata API. Decode a JSON fixture so we don't depend on
    // the (potentially private) memberwise initializer.
    private func metadata(uptimeUp: Bool? = nil,
                          songName: String? = nil,
                          listeners: Int? = nil) throws -> StationMetadata {
        var dict: [String: Any] = ["id": 1]
        if let up = uptimeUp {
            dict["uptime"] = ["is_up": up, "timestamp": "ts"]
        }
        var np: [String: Any] = [:]
        if let n = songName {
            np["song"] = ["id": 1, "name": n]
        }
        if let l = listeners {
            np["listeners"] = l
        }
        if !np.isEmpty {
            dict["now_playing"] = np
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(StationMetadata.self, from: data)
    }

    func test_merging_replaces_uptime_and_nowPlaying() throws {
        let original = makeStation(
            uptime: Uptime(isUp: true, timestamp: "old"),
            nowPlaying: nil
        )
        let m = try metadata(uptimeUp: false, songName: "X", listeners: 33)
        let merged = original.merging(m, liveListeners: nil)
        XCTAssertEqual(merged.uptime?.isUp, false)
        XCTAssertEqual(merged.nowPlaying?.song?.name, "X")
        XCTAssertEqual(merged.totalListeners, 33)
    }

    func test_merging_prefers_liveListeners_over_metadata_listeners() throws {
        let original = makeStation(totalListeners: 1)
        let m = try metadata(songName: "Y", listeners: 99)
        let merged = original.merging(m, liveListeners: 7)
        XCTAssertEqual(merged.totalListeners, 7)
    }

    func test_merging_falls_back_to_existing_listeners() throws {
        let original = makeStation(totalListeners: 5)
        let m = try metadata(songName: "Z")  // listeners nil
        let merged = original.merging(m, liveListeners: nil)
        XCTAssertEqual(merged.totalListeners, 5)
    }

    func test_merging_preserves_missing_uptime_never_synthesizes_down() throws {
        // Stations that never appear in /stations-metadata (private stations)
        // or whose metadata omits uptime must keep their existing uptime —
        // the merge must not invent a "down" state for them.
        let original = makeStation(uptime: nil, nowPlaying: nil)
        let m = try metadata(songName: "Song")  // no uptime key
        let merged = original.merging(m, liveListeners: nil)
        XCTAssertNil(merged.uptime)
        XCTAssertTrue(merged.isUp)
    }
}
