import XCTest
@testable import RadioCrestinTV

/// The address under a QR code, as VoiceOver reads it.
final class SheetAddressTests: XCTestCase {

    private func spoken(_ address: String) -> String {
        ShareSheet.spokenAddress(of: URL(string: address)!)
    }

    func test_the_scheme_is_left_out() {
        XCTAssertEqual(
            spoken("https://www.radiocrestin.ro/terms"),
            "www.radiocrestin.ro/terms"
        )
        XCTAssertEqual(spoken("http://radiocrestin.ro"), "radiocrestin.ro")
    }

    func test_a_station_page_keeps_its_path() {
        XCTAssertEqual(
            spoken("https://www.radiocrestin.ro/radio/radio-eldad"),
            "www.radiocrestin.ro/radio/radio-eldad"
        )
    }

    /// Only a `scheme://` prefix goes: an address without one stays whole.
    func test_an_address_without_slashes_stays_whole() {
        XCTAssertEqual(spoken("mailto:contact@radiocrestin.ro"),
                       "mailto:contact@radiocrestin.ro")
    }
}
