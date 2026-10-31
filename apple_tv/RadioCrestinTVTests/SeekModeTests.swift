import AVFoundation
import XCTest
@testable import RadioCrestinTV

/// "Încărcare în avans": the start variants it loads, its default and how
/// it is kept, and the hold proxy's kill switch.
@MainActor
final class SeekModeTests: XCTestCase {
    private let live = URL(string:
        "https://hls.radiocrestin.ro/hls/radio-gosen/index.m3u8?ref=radio-crestin-apple-tv&s=abc"
    )!

    // MARK: - Start variants

    func test_two_and_five_minutes_load_the_origins_variants_keeping_the_query() {
        XCTAssertEqual(
            HlsStartVariant.url(for: live, mode: .twoMinutes)?.absoluteString,
            "https://hls.radiocrestin.ro/hls/radio-gosen/index-2m.m3u8?ref=radio-crestin-apple-tv&s=abc"
        )
        XCTAssertEqual(
            HlsStartVariant.url(for: live, mode: .fiveMinutes)?.absoluteString,
            "https://hls.radiocrestin.ro/hls/radio-gosen/index-5m.m3u8?ref=radio-crestin-apple-tv&s=abc"
        )
    }

    func test_live_another_host_or_another_playlist_has_no_variant() {
        XCTAssertNil(HlsStartVariant.url(for: live, mode: .instant))
        XCTAssertNil(HlsStartVariant.url(
            for: URL(string: "https://example.com/hls/x/index.m3u8")!,
            mode: .twoMinutes
        ))
        XCTAssertNil(HlsStartVariant.url(
            for: URL(string: "https://hls.radiocrestin.ro/hls/x/other.m3u8")!,
            mode: .twoMinutes
        ))
        XCTAssertNil(HlsStartVariant.url(
            for: URL(string: "https://stream.example.ro/live.mp3")!,
            mode: .fiveMinutes
        ))
    }

    func test_offsets_and_the_phones_default() {
        XCTAssertEqual(SeekMode.default, .twoMinutes)
        XCTAssertEqual(SeekMode.instant.offset, 0)
        XCTAssertEqual(SeekMode.twoMinutes.offset, 120)
        XCTAssertEqual(SeekMode.fiveMinutes.offset, 300)
    }

    /// AVFoundation's error for a start variant the origin answers with
    /// 404, as measured on tvOS 27: the stream's own playlist then loads.
    func test_a_missing_playlist_is_told_apart_from_other_failures() {
        let http404 = NSError(
            domain: "CoreMediaErrorDomain", code: -12938,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 404: File Not Found"]
        )
        XCTAssertTrue(AudioPlayer.isNotFound(NSError(
            domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist,
            userInfo: [NSUnderlyingErrorKey: http404]
        )))
        XCTAssertTrue(AudioPlayer.isNotFound(NSError(
            domain: AVFoundationErrorDomain, code: -11800,
            userInfo: [NSUnderlyingErrorKey: http404]
        )))
        XCTAssertFalse(AudioPlayer.isNotFound(
            URLError(.networkConnectionLost)
        ))
        XCTAssertFalse(AudioPlayer.isNotFound(nil))
    }

    // MARK: - The setting

    func test_the_setting_starts_at_two_minutes_and_is_kept() throws {
        let suite = "SeekModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppState(defaults: defaults)
        XCTAssertEqual(first.seekMode, .twoMinutes)
        first.seekMode = .fiveMinutes

        XCTAssertEqual(AppState(defaults: defaults).seekMode, .fiveMinutes)
    }

    // MARK: - Kill switch

    func test_the_hold_proxy_stays_on_unless_its_flag_is_off() {
        XCTAssertTrue(HlsHoldProxyFlag.isEnabled(flagValue: nil))
        XCTAssertTrue(HlsHoldProxyFlag.isEnabled(flagValue: true))
        XCTAssertTrue(HlsHoldProxyFlag.isEnabled(flagValue: "variant"))
        XCTAssertFalse(HlsHoldProxyFlag.isEnabled(flagValue: false))
    }
}
