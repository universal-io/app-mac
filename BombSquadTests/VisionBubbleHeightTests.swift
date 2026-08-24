import XCTest
@testable import Universal_IO

/// The answer area's height, which has to land on a line boundary.
///
/// Cutting a line through the middle of its glyphs reads as a broken renderer
/// rather than as more text below — the answer looked damaged even though
/// scrolling reached all of it. Nothing throws when the height is arbitrary, so
/// the rule lives here.
final class VisionBubbleHeightTests: XCTestCase {
    /// Whatever budget it is given, the result is a whole number of lines.
    func testEveryHeightIsAWholeNumberOfLines() {
        // A range of real screens and awkward values in between.
        for budget in stride(from: 64.0, through: 1200.0, by: 7.3) {
            let height = VisionBubbleView.answerHeight(within: CGFloat(budget))
            let lines = height / VisionBubbleView.answerLineHeight
            XCTAssertEqual(
                lines, lines.rounded(),
                "height \(height) for budget \(budget) is not a whole number of lines"
            )
        }
    }

    /// It never asks for more room than it was given: the other half of the
    /// screen is the thing the answer is about.
    func testItNeverExceedsItsBudget() {
        for budget in [200.0, 360.0, 558.0, 1000.0] {
            let height = VisionBubbleView.answerHeight(within: CGFloat(budget))
            XCTAssertLessThanOrEqual(height, CGFloat(budget))
        }
    }

    /// A bigger screen gets a taller answer. The number that used to be fixed at
    /// 360 is now derived, so this is what says it actually grew.
    func testABiggerScreenGetsMoreLines() {
        let small = VisionBubbleView.answerHeight(within: 300)
        let large = VisionBubbleView.answerHeight(within: 558)
        XCTAssertGreaterThan(large, small)
        XCTAssertGreaterThan(large, 360, "the answer area did not grow past the old fixed height")
    }

    /// Below four lines a scroll view shows too little for its own scrolling to
    /// make sense. No real display is that small, and a zero-height answer area
    /// would be a blank card.
    func testItNeverCollapsesBelowFourLines() {
        XCTAssertEqual(
            VisionBubbleView.answerHeight(within: 0),
            VisionBubbleView.answerHeight(within: 10)
        )
        XCTAssertGreaterThan(VisionBubbleView.answerHeight(within: 0), 40)
    }
}
