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
}
