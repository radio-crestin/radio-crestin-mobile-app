import XCTest
@testable import RadioCrestinTV

/// Covers the stall watchdog rules and the playability allowlist now that
/// YouTube entries resolve natively.
final class StallRecoveryPolicyTests: XCTestCase {

    // MARK: - Stall detection

    func test_a_briefly_frozen_clock_is_not_a_stall() {
        XCTAssertFalse(StallRecoveryPolicy.isStalled(frozenFor: 0))
        XCTAssertFalse(StallRecoveryPolicy.isStalled(frozenFor: 5.9))
    }

    func test_a_clock_frozen_past_the_grace_window_is_a_stall() {
        XCTAssertTrue(StallRecoveryPolicy.isStalled(frozenFor: 6))
        XCTAssertTrue(StallRecoveryPolicy.isStalled(frozenFor: 30))
    }

    func test_recovery_escalates_cheapest_first() {
        XCTAssertEqual(StallRecoveryPolicy.action(for: 1), .seekToLiveEdge)
        XCTAssertEqual(StallRecoveryPolicy.action(for: 2), .reloadItem)
        XCTAssertEqual(StallRecoveryPolicy.action(for: 3), .giveUp)
        XCTAssertEqual(StallRecoveryPolicy.action(for: 9), .giveUp)
    }

    func test_watchdog_sampling_is_faster_than_the_grace_window() {
        // Otherwise a stall could be missed entirely between samples.
        XCTAssertLessThan(
            StallRecoveryPolicy.sampleInterval, StallRecoveryPolicy.stallGrace
        )
    }

    // MARK: - Controls stay honest while stalled

    func test_controls_do_not_auto_hide_over_a_frozen_frame() {
        XCTAssertFalse(ControlsAutoHidePolicy.shouldAutoHide(
            isPlaying: true, hasError: false, isStalled: true
        ))
    }

    func test_controls_still_auto_hide_during_healthy_playback() {
        XCTAssertTrue(ControlsAutoHidePolicy.shouldAutoHide(
            isPlaying: true, hasError: false, isStalled: false
        ))
    }

    /// Scope reminder, enforced by review rather than by the type system:
    /// `ControlsAutoHidePolicy` governs the VIDEO overlay only. The radio
    /// / audio now-playing screen keeps its chrome on screen permanently,
    /// so it must have no auto-hide state at all.
    func test_auto_hide_is_scoped_to_video_only() throws {
        let source = try String(
            contentsOfFile: #filePath
                .replacingOccurrences(
                    of: "RadioCrestinTVTests/StallRecoveryPolicyTests.swift",
                    with: "RadioCrestinTV/Sources/Views/NowPlayingView.swift"
                ),
            encoding: .utf8
        )
        // Every auto-hide reference must live below the video overlay's
        // MARK — i.e. inside `VideoNowPlaying`, never in the audio layout.
        let videoSectionStart = try XCTUnwrap(
            source.range(of: "// MARK: - Video Now Playing")
        ).lowerBound
        var searchFrom = source.startIndex
        var referenceCount = 0
        while let hit = source.range(
            of: "ControlsAutoHidePolicy", range: searchFrom..<source.endIndex
        ) {
            referenceCount += 1
            XCTAssertGreaterThan(
                hit.lowerBound, videoSectionStart,
                "auto-hide must be used only by the video overlay"
            )
            searchFrom = hit.upperBound
        }
        XCTAssertGreaterThan(referenceCount, 0, "video overlay should still auto-hide")
        XCTAssertFalse(
            source.contains("chromeVisible"),
            "the audio now-playing screen must not hide or dim its chrome"
        )
    }

    // MARK: - Playability allowlist

    private func item(_ type: String) -> PlaylistItem {
        PlaylistItem(
            id: 1, order: 1, type: type,
            url: "https://www.youtube.com/watch?v=M7lc1UVf-VE",
            title: "t", thumbnailUrl: nil, durationSeconds: nil
        )
    }

    func test_youtube_items_are_now_playable_on_tvos() {
        XCTAssertTrue(item("youtube").isPlayable)
        XCTAssertTrue(item("youtube_playlist").isPlayable)
        XCTAssertTrue(item("youtube").needsYoutubeResolution)
        XCTAssertTrue(item("youtube_playlist").needsYoutubeResolution)
    }

    func test_audio_and_video_items_never_go_through_the_resolver() {
        XCTAssertTrue(item("audio").isPlayable)
        XCTAssertTrue(item("video").isPlayable)
        XCTAssertFalse(item("audio").needsYoutubeResolution)
        XCTAssertFalse(item("video").needsYoutubeResolution)
    }

    func test_unknown_types_remain_unplayable() {
        XCTAssertFalse(item("vimeo").isPlayable)
        XCTAssertFalse(item("").isPlayable)
    }

    func test_youtube_items_use_the_video_layout_audio_does_not() {
        XCTAssertTrue(item("youtube").rendersVideo)
        XCTAssertTrue(item("video").rendersVideo)
        XCTAssertFalse(item("audio").rendersVideo)
    }

    func test_a_youtube_only_playlist_is_no_longer_treated_as_unplayable() {
        let station = Station(
            id: 1, slug: "test-bcev-live-dev", title: "BCEV", order: 0,
            thumbnailUrl: nil, totalListeners: nil, stationStreams: [],
            uptime: nil, nowPlaying: nil, reviewsStats: nil,
            stationType: "playlist",
            playlistItems: [item("youtube"), item("youtube")],
            hlsDvrStreamUrl: nil
        )
        XCTAssertEqual(station.playableItems.count, 2)
        XCTAssertFalse(station.hasOnlyUnplayableItems)
    }
}
