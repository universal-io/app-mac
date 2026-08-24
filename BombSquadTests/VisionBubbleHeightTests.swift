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

    /// It never asks for more room than it was given.
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

    /// The bubble as a whole has to fit the screen it is drawn on.
    ///
    /// This is the rule the old "half the display" number was standing in for,
    /// and the reason it can now be raised safely: the placement can move a
    /// bubble that is too tall, but it cannot shrink one, so a budget that
    /// leaves no room for the handle, the question, the input and the margins
    /// puts the top of the answer above the menu bar.
    func testTheWholeBubbleStillFitsTheScreen() {
        for visible in stride(from: 500.0, through: 2000.0, by: 11.0) {
            let budget = VisionBubbleView.answerHeightBudget(visibleHeight: CGFloat(visible))
            let total = VisionBubbleView.answerHeight(within: budget)
                + VisionBubbleView.chromeHeight
            XCTAssertLessThanOrEqual(
                total, CGFloat(visible),
                "a \(visible)pt display would get a \(total)pt bubble"
            )
        }
    }

    /// The answer got more room than the half-screen rule it replaced, on the
    /// displays this actually runs on. Without this the change is a refactor.
    func testTheAnswerGrewPastHalfTheScreen() {
        for visible in [900.0, 1117.0, 1440.0] {
            let now = VisionBubbleView.answerHeightBudget(visibleHeight: CGFloat(visible))
            XCTAssertGreaterThan(
                now, CGFloat(visible) / 2,
                "\(visible)pt display did not gain any room"
            )
        }
    }

    /// A display small enough that two thirds of it would not leave room for
    /// everything else gets the room that is left, not the share.
    func testASmallDisplayGetsWhatIsLeftRatherThanItsShare() {
        let visible: CGFloat = 600
        XCTAssertEqual(
            VisionBubbleView.answerHeightBudget(visibleHeight: visible),
            visible - VisionBubbleView.chromeHeight
        )
    }

    /// The question box follows what is being typed, between a floor of one
    /// line and a ceiling that leaves the answer the larger share.
    func testTheInputFollowsItsTextWithinBounds() {
        let budget = VisionBubbleView.answerHeightBudget(visibleHeight: 1117)
        XCTAssertEqual(
            VisionBubbleView.inputHeight(content: 0, within: budget),
            VisionBubbleView.inputMinHeight,
            "an empty question box collapsed below one line"
        )
        XCTAssertEqual(
            VisionBubbleView.inputHeight(content: 96, within: budget), 96,
            "the field did not follow the text it was given"
        )
        XCTAssertLessThanOrEqual(
            VisionBubbleView.inputHeight(content: 5000, within: budget), 160,
            "a long question was allowed to take the whole bubble"
        )
    }

    /// On a small display the ceiling comes from the budget rather than from the
    /// ten-line constant, and never falls below one line.
    func testTheInputCeilingShrinksWithTheBudget() {
        let small = VisionBubbleView.inputHeight(content: 5000, within: 120)
        XCTAssertLessThanOrEqual(small, 40)
        XCTAssertGreaterThanOrEqual(small, VisionBubbleView.inputMinHeight)
        XCTAssertEqual(
            VisionBubbleView.inputHeight(content: 5000, within: 0),
            VisionBubbleView.inputMinHeight
        )
    }
}
