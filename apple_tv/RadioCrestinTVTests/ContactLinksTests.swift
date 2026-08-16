import XCTest
@testable import RadioCrestinTV

/// The support QR's payload is built by a pure function so it can be
/// verified without a device: these tests pin the message shape, the
/// encoding, and the length discipline the QR depends on.
final class ContactLinksTests: XCTestCase {

    private func diagnostics(
        title: String? = "Radio Elim",
        slug: String? = "radio-elim",
        source: String? = nil
    ) -> ContactLinks.Diagnostics {
        ContactLinks.Diagnostics(
            stationTitle: title,
            stationSlug: slug,
            failingSource: source,
            deviceId: "ACBAD209-2BC8-4DCC-BC0F-8EB109C37F47",
            appVersion: "1.5.0(83)",
            systemVersion: "26.4"
        )
    }

    // MARK: - Message body

    func test_message_opens_with_the_romanian_greeting_and_problem() {
        let message = ContactLinks.supportMessage(diagnostics())
        XCTAssertTrue(message.hasPrefix("Bună ziua,\n"))
        XCTAssertTrue(message.contains("am o problemă cu redarea pe Apple TV."))
    }

    func test_message_carries_every_diagnostic_field() {
        let message = ContactLinks.supportMessage(
            diagnostics(source: "https://hls.radiocrestin.ro/hls/radio-elim/index.m3u8")
        )
        XCTAssertTrue(message.contains("Radio Elim"))
        XCTAssertTrue(message.contains("radio-elim"))
        // The stream URL is present but trimmed — see `maxSourceLength`;
        // support only needs enough to identify the host/path.
        XCTAssertTrue(message.contains("Sursă: https://hls.radiocrestin.ro"))
        XCTAssertTrue(message.contains("1.5.0(83)"))
        XCTAssertTrue(message.contains("tvOS 26.4"))
        XCTAssertTrue(message.contains("ACBAD209-2BC8-4DCC-BC0F-8EB109C37F47"))
    }

    func test_unknown_fields_are_simply_omitted() {
        let message = ContactLinks.supportMessage(
            ContactLinks.Diagnostics(
                deviceId: "DEV", appVersion: "1.0(1)", systemVersion: "26.4"
            )
        )
        XCTAssertFalse(message.contains("Post:"))
        XCTAssertFalse(message.contains("Sursă:"))
        XCTAssertTrue(message.contains("ID: DEV"))
    }

    func test_slug_only_still_names_the_station() {
        let message = ContactLinks.supportMessage(
            diagnostics(title: nil, slug: "radio-elim")
        )
        XCTAssertTrue(message.contains("Post: radio-elim"))
    }

    // MARK: - QR payload discipline

    func test_a_very_long_source_is_truncated_to_protect_qr_readability() {
        let long = String(repeating: "x", count: 400)
        let message = ContactLinks.supportMessage(diagnostics(source: long))
        XCTAssertFalse(message.contains(long))
        XCTAssertTrue(message.contains("…"))
        XCTAssertLessThanOrEqual(
            ContactLinks.truncate(long).count, ContactLinks.maxSourceLength
        )
    }

    func test_encoded_payload_stays_short_enough_to_scan() {
        let url = ContactLinks.whatsAppURL(
            diagnostics(source: "https://hls.radiocrestin.ro/hls/radio-elim/index.m3u8")
        )
        XCTAssertNotNil(url)
        // Comfortably inside the density where a QR stays readable at 10ft.
        XCTAssertLessThan(url!.absoluteString.count, 600)
    }

    // MARK: - URL shape

    func test_url_targets_the_real_support_number() {
        let url = ContactLinks.whatsAppURL(diagnostics())!
        XCTAssertTrue(
            url.absoluteString.hasPrefix("https://wa.me/40766338046?text=")
        )
    }

    func test_encoding_matches_encodeURIComponent() {
        // Spaces -> %20 and newlines -> %0A, matching the phone apps.
        let encoded = ContactLinks.percentEncoded("a b\nc")
        XCTAssertEqual(encoded, "a%20b%0Ac")
    }

    func test_diacritics_survive_a_round_trip() {
        let url = ContactLinks.whatsAppURL(diagnostics())!
        let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "text" })?.value
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("Bună ziua"))
        XCTAssertTrue(text!.contains("problemă"))
    }
}
