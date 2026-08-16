import XCTest
@testable import RadioCrestinTV

/// Parsing + URL-extraction tests for `YoutubeStreamResolver`.
///
/// Everything here runs against fixture JSON — no network. Innertube is an
/// unofficial API, so these fixtures double as documentation of the exact
/// response shapes the resolver is known to handle; when YouTube changes
/// the schema, a fixture is what has to be updated.
final class YoutubeStreamResolverTests: XCTestCase {

    private func json(_ raw: String) -> Data { Data(raw.utf8) }

    // MARK: - Video id extraction

    func test_extracts_id_from_watch_url() {
        XCTAssertEqual(
            YoutubeStreamResolver.videoId(from: "https://www.youtube.com/watch?v=M7lc1UVf-VE"),
            "M7lc1UVf-VE"
        )
    }

    func test_extracts_id_from_the_real_bcev_urls() {
        XCTAssertEqual(
            YoutubeStreamResolver.videoId(from: "https://www.youtube.com/watch?v=X3RvK_bJris"),
            "X3RvK_bJris"
        )
    }

    func test_extracts_id_from_short_live_embed_and_shorts_urls() {
        let cases = [
            "https://youtu.be/M7lc1UVf-VE": "M7lc1UVf-VE",
            "https://www.youtube.com/live/M7lc1UVf-VE": "M7lc1UVf-VE",
            "https://www.youtube.com/embed/M7lc1UVf-VE": "M7lc1UVf-VE",
            "https://www.youtube.com/shorts/M7lc1UVf-VE": "M7lc1UVf-VE"
        ]
        for (url, expected) in cases {
            XCTAssertEqual(YoutubeStreamResolver.videoId(from: url), expected, url)
        }
    }

    func test_extracts_id_when_extra_query_params_are_present() {
        XCTAssertEqual(
            YoutubeStreamResolver.videoId(
                from: "https://www.youtube.com/watch?v=M7lc1UVf-VE&list=PLC77007E23FF423C6&index=2"
            ),
            "M7lc1UVf-VE"
        )
    }

    func test_playlist_only_url_has_no_video_id() {
        let url = "https://www.youtube.com/playlist?list=PLC77007E23FF423C6"
        XCTAssertNil(YoutubeStreamResolver.videoId(from: url))
        XCTAssertEqual(
            YoutubeStreamResolver.playlistId(from: url), "PLC77007E23FF423C6"
        )
    }

    func test_non_youtube_urls_are_rejected() {
        XCTAssertNil(YoutubeStreamResolver.videoId(
            from: "https://media.w3.org/2010/05/sintel/trailer.mp4"
        ))
        XCTAssertNil(YoutubeStreamResolver.videoId(from: "not a url at all"))
    }

    func test_id_shape_validation() {
        XCTAssertTrue(YoutubeStreamResolver.isPlausibleId("M7lc1UVf-VE"))
        XCTAssertFalse(YoutubeStreamResolver.isPlausibleId("tooshort"))
        XCTAssertFalse(YoutubeStreamResolver.isPlausibleId("has spaces!!"))
    }

    // MARK: - Response parsing: success paths

    func test_live_broadcast_resolves_to_the_hls_manifest() throws {
        let fixture = json("""
        {
          "playabilityStatus": {"status": "OK"},
          "streamingData": {
            "expiresInSeconds": "21540",
            "hlsManifestUrl": "https://manifest.googlevideo.com/api/manifest/hls_variant/x/index.m3u8",
            "formats": [
              {"itag": 18, "url": "https://example.com/prog.mp4",
               "mimeType": "video/mp4; codecs=\\"avc1.42001E, mp4a.40.2\\"", "height": 360}
            ]
          },
          "videoDetails": {"title": "BCEV Live", "isLive": true}
        }
        """)
        let resolved = try YoutubeStreamResolver.parse(fixture)
        // HLS must win over the progressive entry — it is adaptive and
        // native to AVPlayer.
        XCTAssertEqual(
            resolved.url.absoluteString,
            "https://manifest.googlevideo.com/api/manifest/hls_variant/x/index.m3u8"
        )
        XCTAssertTrue(resolved.isHLS)
        XCTAssertTrue(resolved.isLive)
        XCTAssertEqual(resolved.title, "BCEV Live")
        XCTAssertEqual(resolved.expiresIn, 21540)
    }

    func test_vod_without_hls_falls_back_to_the_best_muxed_progressive() throws {
        let fixture = json("""
        {
          "playabilityStatus": {"status": "OK"},
          "streamingData": {
            "expiresInSeconds": "600",
            "formats": [
              {"itag": 18, "url": "https://example.com/360.mp4",
               "mimeType": "video/mp4; codecs=\\"avc1.42001E, mp4a.40.2\\"", "height": 360},
              {"itag": 22, "url": "https://example.com/720.mp4",
               "mimeType": "video/mp4; codecs=\\"avc1.64001F, mp4a.40.2\\"", "height": 720}
            ]
          },
          "videoDetails": {"title": "Demo", "isLive": false}
        }
        """)
        let resolved = try YoutubeStreamResolver.parse(fixture)
        XCTAssertEqual(resolved.url.absoluteString, "https://example.com/720.mp4",
                       "should pick the highest muxed rendition")
        XCTAssertFalse(resolved.isHLS)
        XCTAssertFalse(resolved.isLive)
    }

    func test_missing_expiry_falls_back_to_a_safe_default() throws {
        let fixture = json("""
        {"playabilityStatus":{"status":"OK"},
         "streamingData":{"hlsManifestUrl":"https://example.com/a.m3u8"},
         "videoDetails":{"title":"x"}}
        """)
        XCTAssertEqual(try YoutubeStreamResolver.parse(fixture).expiresIn, 300)
    }

    // MARK: - Response parsing: failure paths (these drive the skip-card)

    func test_bot_check_is_reported_as_unplayable() {
        let fixture = json("""
        {"playabilityStatus":{"status":"LOGIN_REQUIRED",
          "reason":"Sign in to confirm you’re not a bot"}}
        """)
        XCTAssertThrowsError(try YoutubeStreamResolver.parse(fixture)) { error in
            guard case YoutubeStreamResolver.ResolveError.unplayable(let reason) = error
            else { return XCTFail("expected .unplayable, got \(error)") }
            XCTAssertTrue(reason.contains("bot"))
        }
    }

    func test_geo_or_age_block_is_reported_as_unplayable() {
        let fixture = json("""
        {"playabilityStatus":{"status":"UNPLAYABLE","reason":"Video unavailable"}}
        """)
        XCTAssertThrowsError(try YoutubeStreamResolver.parse(fixture))
    }

    func test_http_error_envelope_is_reported_as_unplayable() {
        let fixture = json("""
        {"error":{"code":400,"message":"Precondition check failed.",
          "status":"FAILED_PRECONDITION"}}
        """)
        XCTAssertThrowsError(try YoutubeStreamResolver.parse(fixture)) { error in
            guard case YoutubeStreamResolver.ResolveError.unplayable(let reason) = error
            else { return XCTFail("expected .unplayable, got \(error)") }
            XCTAssertTrue(reason.contains("Precondition"))
        }
    }

    /// The current real-world shape for many VODs: YouTube's SABR
    /// migration leaves only split audio/video renditions, which AVPlayer
    /// cannot recombine. Must fail cleanly so the UI degrades.
    func test_adaptive_only_response_yields_no_compatible_stream() {
        let fixture = json("""
        {
          "playabilityStatus": {"status": "OK"},
          "streamingData": {
            "expiresInSeconds": "21540",
            "serverAbrStreamingUrl": "https://example.com/sabr",
            "adaptiveFormats": [
              {"itag": 137, "url": "https://example.com/v.mp4",
               "mimeType": "video/mp4; codecs=\\"avc1.640028\\"", "height": 1080},
              {"itag": 140, "url": "https://example.com/a.m4a",
               "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\""}
            ]
          },
          "videoDetails": {"title": "SABR only"}
        }
        """)
        XCTAssertThrowsError(try YoutubeStreamResolver.parse(fixture)) { error in
            guard case YoutubeStreamResolver.ResolveError.noCompatibleStream = error
            else { return XCTFail("expected .noCompatibleStream, got \(error)") }
        }
    }

    func test_ciphered_progressive_urls_are_skipped() {
        // Without a JS engine we cannot unscramble `signatureCipher`.
        let fixture = json("""
        {
          "playabilityStatus": {"status": "OK"},
          "streamingData": {
            "formats": [
              {"itag": 18, "signatureCipher": "s=abc&url=https%3A%2F%2Fx",
               "mimeType": "video/mp4; codecs=\\"avc1, mp4a\\"", "height": 360}
            ]
          },
          "videoDetails": {"title": "ciphered"}
        }
        """)
        XCTAssertThrowsError(try YoutubeStreamResolver.parse(fixture))
    }

    func test_audio_only_progressive_entry_is_not_accepted_as_video() {
        let fixture = json("""
        {
          "playabilityStatus": {"status": "OK"},
          "streamingData": {
            "formats": [
              {"itag": 140, "url": "https://example.com/a.m4a",
               "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\""}
            ]
          },
          "videoDetails": {"title": "audio"}
        }
        """)
        XCTAssertThrowsError(try YoutubeStreamResolver.parse(fixture))
    }

    func test_garbage_payload_does_not_crash() {
        XCTAssertThrowsError(try YoutubeStreamResolver.parse(Data("<html>".utf8)))
        XCTAssertThrowsError(try YoutubeStreamResolver.parse(Data()))
    }
}
