import XCTest
@testable import RadioCrestinTV

/// How a focused card's line scrolls when it does not fit (`MarqueeLoop`).
final class MarqueeLoopTests: XCTestCase {

    func test_a_line_that_fits_stays_still() {
        XCTAssertFalse(MarqueeLoop.overflows(line: 180, box: 225))
        XCTAssertFalse(MarqueeLoop.overflows(line: 225, box: 225))
    }

    /// Sizes measured a hair apart are not a cut line.
    func test_rounding_is_not_an_overflow() {
        XCTAssertFalse(MarqueeLoop.overflows(line: 225.4, box: 225))
    }

    /// The line can be measured before its box: until both are, nothing
    /// scrolls, so a short line never flashes the moving copy.
    func test_an_unmeasured_box_cuts_nothing() {
        XCTAssertFalse(MarqueeLoop.overflows(line: 180, box: 0))
    }

    func test_a_cut_line_scrolls() {
        XCTAssertTrue(MarqueeLoop.overflows(line: 226, box: 225))
        XCTAssertTrue(MarqueeLoop.overflows(line: 336, box: 225))
    }

    /// One pass moves the line by its own width and the gap, so its copy
    /// ends exactly where the line started and the next pass shows no
    /// jump.
    func test_a_pass_ends_with_the_copy_at_the_start() {
        let loop = MarqueeLoop(lineWidth: 335)

        XCTAssertEqual(loop.travel, 335 + MarqueeLoop.gap)
    }

    /// The system's steady 45 pt/s, whatever the line's length.
    func test_a_pass_moves_at_a_steady_speed() {
        let short = MarqueeLoop(lineWidth: 240)
        let long = MarqueeLoop(lineWidth: 480)

        XCTAssertEqual(short.duration, 280 / 45, accuracy: 0.001)
        XCTAssertEqual(long.duration, 520 / 45, accuracy: 0.001)
        XCTAssertEqual(long.period, long.duration + MarqueeLoop.rest)
    }

    /// The focused card draws its line larger: on screen the line still
    /// moves at 45 pt/s, with the system's gap and fades.
    func test_the_card_lift_keeps_the_system_sizes_on_screen() {
        let scale: CGFloat = 1.12
        let loop = MarqueeLoop(lineWidth: 300, scale: scale)

        XCTAssertEqual(
            (loop.travel - 300) * scale, MarqueeLoop.gap, accuracy: 0.001
        )
        XCTAssertEqual(
            loop.fadeWidth * scale, MarqueeLoop.fadeWidth, accuracy: 0.001
        )
        let onScreenSpeed = loop.travel * scale / CGFloat(loop.duration)
        XCTAssertEqual(onScreenSpeed, MarqueeLoop.speed, accuracy: 0.001)
    }

    /// The leading fade leaves while the empty gap passes under it, before
    /// the copy's first letter reaches the edge it would dim.
    func test_the_leading_fade_leaves_before_the_copy_arrives() {
        let loop = MarqueeLoop(lineWidth: 335)
        let copyDistance = { (time: CFTimeInterval) in
            loop.travel - MarqueeLoop.speed * CGFloat(time)
        }

        XCTAssertGreaterThan(loop.leadingFadeEnd, MarqueeLoop.fadeDuration)
        let fadeGone = loop.leadingFadeEnd + MarqueeLoop.fadeDuration
        XCTAssertLessThan(fadeGone, loop.duration)
        XCTAssertGreaterThan(copyDistance(fadeGone), MarqueeLoop.fadeWidth)
    }
}
