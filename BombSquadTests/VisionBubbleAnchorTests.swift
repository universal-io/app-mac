import AppKit
import XCTest
@testable import Universal_IO

/// The bubble moves once per gesture.
///
/// The ring goes up the instant the click is heard; the element under it is
/// measured about half a second later. If both place the bubble, the card is
/// shoved from one spot to another while the user is still looking at where
/// they clicked. This has now been fixed twice — the second time because the
/// call to place the bubble was removed from `showRing` while the assignment to
/// the anchor was left in, and the reflow that follows the bubble's change of
/// height carried out the move instead.
///
/// So the rule is stated against the anchor, not against the call: showing a
/// mark must not change where the placement would put the card.
///
/// That was still not enough, and the tests below are why it took a third time
/// to see it: every one of them asks about the anchor, so all five passed while
/// the card was visibly jumping. Where it sits is solved from three things, and
/// a click changes the other two by itself — the answer becomes
/// "ここを読んでいます…" so the card's height changes, and the measured frame is
/// cleared out of what it must avoid. `testGuardingTheAnchorCannotHoldTheCardStill`
/// states that directly, and the resize tests state the fix: a reflow keeps the
/// top-left instead of solving the placement again.
@MainActor
final class VisionBubbleAnchorTests: XCTestCase {
    private let size = CGSize(width: 380, height: 300)
    private let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    private func placed(_ anchor: BubbleAnchor) -> CGPoint {
        VisionBubblePlacement.origin(for: anchor, size: size, in: bounds)
    }

    func testRingDoesNotChangeWhereTheBubbleWouldGo() {
        let overlay = VisionPointingOverlay()
        overlay.setMark(point: CGPoint(x: 300, y: 900), frame: nil)
        let settled = overlay.bubbleAnchor
        XCTAssertNotNil(settled.point)

        // The next click, far from the last one, while the previous answer is
        // still the thing on screen.
        overlay.showRing(at: CGPoint(x: 1500, y: 200))

        XCTAssertEqual(overlay.bubbleAnchor, settled)
        XCTAssertEqual(placed(overlay.bubbleAnchor), placed(settled))
    }

    func testRingLeavesAPositionTheUserChoseAlone() {
        let overlay = VisionPointingOverlay()
        overlay.setMark(point: CGPoint(x: 300, y: 900), frame: nil)
        overlay.showRing(at: CGPoint(x: 1500, y: 200))
        XCTAssertNil(overlay.bubbleAnchor.userTopLeft)

        // And an enclosure's anchor survives a ring too: the line stays on
        // screen as the only statement of what the question was about.
        overlay.setRegion(path: [
            CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 100),
            CGPoint(x: 400, y: 300), CGPoint(x: 100, y: 300),
        ])
        let enclosed = overlay.bubbleAnchor
        XCTAssertNotNil(enclosed.frame)
        overlay.showRing(at: CGPoint(x: 1500, y: 200))
        XCTAssertEqual(overlay.bubbleAnchor, enclosed)
    }

    func testMeasurementIsTheOneMove() {
        let overlay = VisionPointingOverlay()
        overlay.setMark(point: CGPoint(x: 300, y: 900), frame: nil)
        let before = placed(overlay.bubbleAnchor)

        overlay.showRing(at: CGPoint(x: 1500, y: 200))
        overlay.setMark(point: CGPoint(x: 1500, y: 200), frame: CGRect(x: 1460, y: 180, width: 80, height: 40))

        XCTAssertEqual(overlay.bubbleAnchor.point, CGPoint(x: 1500, y: 200))
        XCTAssertNotEqual(placed(overlay.bubbleAnchor), before)
    }

    func testANewSubjectSpendsAPositionTheUserDragged() {
        var anchor = BubbleAnchor(point: CGPoint(x: 300, y: 900))
        anchor.userTopLeft = CGPoint(x: 20, y: 600)
        XCTAssertEqual(
            placed(anchor),
            VisionBubblePlacement.origin(movedTo: CGPoint(x: 20, y: 600), size: size, in: bounds),
            "a dragged position wins over both rules"
        )

        let overlay = VisionPointingOverlay()
        overlay.setMark(point: CGPoint(x: 300, y: 900), frame: nil)
        XCTAssertNil(overlay.bubbleAnchor.userTopLeft)
    }

    func testTheAnswersFrameWinsOverTheClick() {
        let frame = CGRect(x: 800, y: 500, width: 120, height: 40)
        let anchor = BubbleAnchor(point: CGPoint(x: 300, y: 900), frame: frame)
        XCTAssertEqual(
            placed(anchor),
            VisionBubblePlacement.origin(besideFrame: frame, size: size, in: bounds)
        )
    }

    // MARK: - Growing is not moving

    /// The finding behind the third recurrence: the anchor is one of three
    /// inputs, so holding it still does not hold the card still. Both of the
    /// others change during the ring phase, and the reflow timer re-solves the
    /// placement every tenth of a second with whatever they now are.
    func testGuardingTheAnchorCannotHoldTheCardStill() {
        let anchor = BubbleAnchor(point: CGPoint(x: 900, y: 600))
        let measured = CGRect(x: 880, y: 560, width: 300, height: 80)

        let withFrameAvoided = VisionBubblePlacement.origin(
            for: anchor, size: size, in: bounds, avoid: [measured]
        )
        let afterTheFrameIsCleared = VisionBubblePlacement.origin(
            for: anchor, size: size, in: bounds, avoid: []
        )
        let afterTheAnswerIsSwappedForALoadingLine = VisionBubblePlacement.origin(
            for: anchor,
            size: CGSize(width: size.width, height: 90),
            in: bounds,
            avoid: []
        )

        XCTAssertNotEqual(withFrameAvoided, afterTheFrameIsCleared)
        XCTAssertNotEqual(withFrameAvoided, afterTheAnswerIsSwappedForALoadingLine)
    }

    /// A card that grew keeps its top edge: the text arrives below what is
    /// already being read, which is where a paragraph goes.
    func testAGrowingCardKeepsItsTopEdge() {
        let frame = CGRect(x: 400, y: 500, width: 380, height: 200)
        let grown = VisionBubblePlacement.resized(
            frame, to: CGSize(width: 380, height: 320), in: bounds
        )
        XCTAssertEqual(grown.maxY, frame.maxY)
        XCTAssertEqual(grown.minX, frame.minX)
    }

    func testAShrinkingCardKeepsItsTopEdgeToo() {
        let frame = CGRect(x: 400, y: 500, width: 380, height: 320)
        let shrunk = VisionBubblePlacement.resized(
            frame, to: CGSize(width: 380, height: 120), in: bounds
        )
        XCTAssertEqual(shrunk.maxY, frame.maxY)
        XCTAssertEqual(shrunk.minX, frame.minX)
    }

    /// The current frame is read from the window rather than stored, so a card
    /// the user dragged stays where they put it through every later resize —
    /// the case that used to snap back the moment an answer arrived.
    func testAPositionTheUserDraggedSurvivesEveryResize() {
        var frame = CGRect(x: 1200, y: 800, width: 380, height: 140)
        for height in [220.0, 340.0, 180.0] {
            frame = VisionBubblePlacement.resized(
                frame, to: CGSize(width: 380, height: height), in: bounds
            )
            XCTAssertEqual(frame.maxY, 940)
            XCTAssertEqual(frame.minX, 1200)
        }
    }

    /// Off the bottom of the screen is the one thing worse than moving, so the
    /// clamp still applies — and it is the only movement a resize can cause.
    func testACardTooTallToGrowDownwardStaysOnScreen() {
        let frame = CGRect(x: 400, y: 40, width: 380, height: 120)
        let grown = VisionBubblePlacement.resized(
            frame, to: CGSize(width: 380, height: 600), in: bounds
        )
        XCTAssertGreaterThanOrEqual(grown.minY, bounds.minY)
        XCTAssertLessThanOrEqual(grown.maxY, bounds.maxY)
    }

    // MARK: - One gesture, one move

    /// The measured element is what the card is placed beside, not the pixel
    /// the finger landed on. Anchoring on the click made two moves out of one
    /// gesture: to the ring first, then to the element a second later when the
    /// answer named it — which is usually the element measured here, in the
    /// same place.
    func testTheCardIsPlacedBesideWhatWasMeasured() {
        let overlay = VisionPointingOverlay()
        let element = CGRect(x: 1460, y: 180, width: 80, height: 40)
        overlay.setMark(point: CGPoint(x: 1500, y: 200), frame: element)

        XCTAssertEqual(overlay.bubbleAnchor.frame, element)
        XCTAssertEqual(
            placed(overlay.bubbleAnchor),
            VisionBubblePlacement.origin(besideFrame: element, size: size, in: bounds)
        )
    }

    /// Nothing measured means the click is all there is to go on, and the ring
    /// is already marking it.
    func testAnUnmeasuredClickStillPlacesTheCardBesideTheRing() {
        let overlay = VisionPointingOverlay()
        overlay.setMark(point: CGPoint(x: 1500, y: 200), frame: nil)

        XCTAssertNil(overlay.bubbleAnchor.frame)
        XCTAssertEqual(overlay.bubbleAnchor.point, CGPoint(x: 1500, y: 200))
    }

    /// The answer naming the element that was already measured asks for the
    /// position the card is already in. The two rects travel through separate
    /// conversions, so they can differ by a fraction of a point — which is not
    /// a new subject and must not show up as a twitch.
    func testTheAnswerAboutTheMeasuredElementDoesNotMoveTheCard() {
        let overlay = VisionPointingOverlay()
        let element = CGRect(x: 1460, y: 180, width: 80, height: 40)
        overlay.setMark(point: CGPoint(x: 1500, y: 200), frame: element)
        let settled = overlay.bubbleAnchor

        overlay.showAnswerFrame(element)
        XCTAssertEqual(overlay.bubbleAnchor, settled)

        overlay.showAnswerFrame(element.offsetBy(dx: 0.4, dy: -0.3))
        XCTAssertEqual(overlay.bubbleAnchor, settled)
    }

    /// An answer about a different element is a different subject, and that
    /// move is the one the design asks for: the words belong beside the thing
    /// they are about.
    func testTheAnswerAboutAnotherElementStillMovesTheCard() {
        let overlay = VisionPointingOverlay()
        overlay.setMark(
            point: CGPoint(x: 1500, y: 200),
            frame: CGRect(x: 1460, y: 180, width: 80, height: 40)
        )
        let elsewhere = CGRect(x: 200, y: 800, width: 120, height: 60)

        overlay.showAnswerFrame(elsewhere)
        XCTAssertEqual(overlay.bubbleAnchor.frame, elsewhere)
    }
}
