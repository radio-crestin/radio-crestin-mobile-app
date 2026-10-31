import XCTest
@testable import RadioCrestinTV

/// What a network path update means for the audio engine.
@MainActor
final class NetworkPathWatcherTests: XCTestCase {
    private typealias Path = NetworkPathWatcher.Path

    private let ethernet = Path(isSatisfied: true, interface: "en0")
    private let wifi = Path(isSatisfied: true, interface: "en1")
    private let offline = Path(isSatisfied: false, interface: nil)

    private func event(
        _ old: Path?, _ new: Path
    ) -> NetworkPathWatcher.Event? {
        NetworkPathWatcher.event(from: old, to: new)
    }

    func test_the_path_at_launch_is_neither_a_restore_nor_a_change() {
        XCTAssertNil(event(nil, wifi))
        XCTAssertNil(event(nil, offline))
    }

    func test_a_usable_path_after_none_is_a_restore() {
        XCTAssertEqual(event(offline, wifi), .restored)
        XCTAssertEqual(
            event(Path(isSatisfied: false, interface: "en1"), ethernet),
            .restored,
            "on another interface too: a restore, not a change"
        )
    }

    /// An Ethernet cable plugged in or out while on Wi-Fi: no gap, so no
    /// restore, but connections on the interface left may hang.
    func test_moving_to_another_interface_while_online_is_a_change() {
        XCTAssertEqual(event(wifi, ethernet), .changed)
        XCTAssertEqual(event(ethernet, wifi), .changed)
    }

    func test_an_update_on_the_same_interface_reports_nothing() {
        XCTAssertNil(event(wifi, wifi))
    }

    func test_losing_the_network_reports_nothing() {
        XCTAssertNil(event(wifi, offline))
        XCTAssertNil(event(offline, offline))
        XCTAssertNil(
            event(offline, Path(isSatisfied: false, interface: "en0"))
        )
    }
}
