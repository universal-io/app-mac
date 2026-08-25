import XCTest
@testable import Universal_IO

final class VisionBubblePlacementTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let size = CGSize(width: 360, height: 200)

    func testTheBubbleSitsBesideAndBelowThePointedSpot() {
        let origin = VisionBubblePlacement.origin(
            for: CGPoint(x: 400, y: 700),
            size: size,
            in: bounds
        )
        // Right of the point by the gap, and below it (Cocoa y grows upward, so
        // "below" is a smaller y).
        XCTAssertEqual(origin.x, 420, accuracy: 0.001)
        XCTAssertEqual(origin.y, 700 - 20 - 200, accuracy: 0.001)
    }

    func testItNeverCoversWhatWasPointedAt() {
        let point = CGPoint(x: 400, y: 700)
        let origin = VisionBubblePlacement.origin(for: point, size: size, in: bounds)
        let rect = CGRect(origin: origin, size: size)
        XCTAssertFalse(rect.contains(point), "the bubble is sitting on the spot it explains")
    }

    func testItFlipsToTheLeftRatherThanRunningOffTheRightEdge() {
        let origin = VisionBubblePlacement.origin(
            for: CGPoint(x: 1500, y: 700),
            size: size,
            in: bounds
        )
        XCTAssertEqual(origin.x, 1500 - 20 - 360, accuracy: 0.001)
    }

    func testItFlipsAboveRatherThanRunningOffTheBottomEdge() {
        let origin = VisionBubblePlacement.origin(
            for: CGPoint(x: 400, y: 80),
            size: size,
            in: bounds
        )
        XCTAssertEqual(origin.y, 80 + 20, accuracy: 0.001)
    }

    /// A bubble the user dragged stays where they put it, and stays anchored by
    /// its top: an answer arriving makes the card taller, and holding the origin
    /// instead would slide the whole thing up out from under someone reading it.
    func testAMovedBubbleGrowsDownwardFromWhereItWasPut() {
        let topLeft = CGPoint(x: 500, y: 800)
        let short = VisionBubblePlacement.origin(movedTo: topLeft, size: size, in: bounds)
        let tall = VisionBubblePlacement.origin(
            movedTo: topLeft,
            size: CGSize(width: size.width, height: size.height * 2),
            in: bounds
        )

        XCTAssertEqual(short.x, 500, accuracy: 0.001)
        XCTAssertEqual(short.y + size.height, 800, accuracy: 0.001)
        XCTAssertEqual(tall.x, 500, accuracy: 0.001)
        XCTAssertEqual(tall.y + size.height * 2, 800, accuracy: 0.001, "the top edge moved")
    }

    /// Their position wins, but not off the display: a bubble dragged to the
    /// edge and then grown by a long answer still has to be readable.
    func testAMovedBubbleIsKeptOnScreen() {
        for topLeft in [
            CGPoint(x: -400, y: 40),
            CGPoint(x: 1900, y: 2000),
            CGPoint(x: 800, y: 60),
        ] {
            let rect = CGRect(
                origin: VisionBubblePlacement.origin(movedTo: topLeft, size: size, in: bounds),
                size: size
            )
            XCTAssertTrue(bounds.contains(rect), "bubble left the screen from \(topLeft): \(rect)")
        }
    }

    /// All four corners, because a rule that works in the middle of the screen
    /// and fails at the edges fails exactly where menus and toolbars live.
    func testEveryCornerStaysOnScreen() {
        for point in [
            CGPoint(x: 4, y: 4),
            CGPoint(x: 1596, y: 4),
            CGPoint(x: 4, y: 996),
            CGPoint(x: 1596, y: 996),
        ] {
            let rect = CGRect(
                origin: VisionBubblePlacement.origin(for: point, size: size, in: bounds),
                size: size
            )
            XCTAssertTrue(
                bounds.contains(rect),
                "bubble left the screen for point \(point): \(rect)"
            )
        }
    }

    /// The frame the answer points at carries information the bubble does not.
    /// Covering it turns two marks into one blur — the web client saw this and
    /// made avoidance part of the placement rather than a later fix.
    func testItMovesAsideRatherThanCoveringTheAnswersOwnFrame() {
        let point = CGPoint(x: 400, y: 700)
        let inTheWay = CGRect(x: 420, y: 480, width: 300, height: 180)
        let origin = VisionBubblePlacement.origin(
            for: point,
            size: size,
            in: bounds,
            avoid: [inTheWay]
        )
        let rect = CGRect(origin: origin, size: size)
        XCTAssertFalse(rect.intersects(inTheWay))
        XCTAssertTrue(bounds.contains(rect))
    }

    /// When every side is blocked, staying readable beats staying clear: a
    /// bubble pushed half off the display cannot be read at all.
    func testAnImpossibleSituationKeepsTheBubbleOnScreen() {
        let everywhere = [CGRect(x: 0, y: 0, width: 1600, height: 1000)]
        let rect = CGRect(
            origin: VisionBubblePlacement.origin(
                for: CGPoint(x: 800, y: 500),
                size: size,
                in: bounds,
                avoid: everywhere
            ),
            size: size
        )
        XCTAssertTrue(bounds.contains(rect))
    }

    /// Once the answer has pointed at a frame, the words belong beside that
    /// frame — the frame on one element and the bubble beside another is the
    /// product disagreeing with itself (2026-08-24, GitLab's two "+" buttons).
    func testBesideAFrameTheBubbleSitsToItsRightTopAligned() {
        let frame = CGRect(x: 400, y: 650, width: 120, height: 50)
        let origin = VisionBubblePlacement.origin(
            besideFrame: frame,
            size: size,
            in: bounds
        )
        XCTAssertEqual(origin.x, frame.maxX + 20, accuracy: 0.001)
        XCTAssertEqual(origin.y, frame.maxY - size.height, accuracy: 0.001)
    }

    func testBesideAFrameItNeverCoversTheFrame() {
        let frame = CGRect(x: 400, y: 650, width: 120, height: 50)
        let rect = CGRect(
            origin: VisionBubblePlacement.origin(
                besideFrame: frame, size: size, in: bounds
            ),
            size: size
        )
        XCTAssertFalse(rect.intersects(frame), "the bubble is sitting on the element it explains")
    }

    func testBesideAFrameItFlipsLeftRatherThanRunningOffTheRightEdge() {
        // A frame against the right edge, like a toolbar button in a top-right
        // corner — exactly where the GitLab "+" lives.
        let frame = CGRect(x: 1450, y: 650, width: 120, height: 50)
        let origin = VisionBubblePlacement.origin(
            besideFrame: frame,
            size: size,
            in: bounds
        )
        XCTAssertEqual(origin.x, frame.minX - 20 - size.width, accuracy: 0.001)
    }

    func testBesideAFrameEveryCornerStaysOnScreen() {
        for frame in [
            CGRect(x: 4, y: 4, width: 80, height: 30),
            CGRect(x: 1516, y: 4, width: 80, height: 30),
            CGRect(x: 4, y: 966, width: 80, height: 30),
            CGRect(x: 1516, y: 966, width: 80, height: 30),
        ] {
            let rect = CGRect(
                origin: VisionBubblePlacement.origin(
                    besideFrame: frame, size: size, in: bounds
                ),
                size: size
            )
            XCTAssertTrue(
                bounds.contains(rect),
                "bubble left the screen for frame \(frame): \(rect)"
            )
        }
    }

    func testWithNothingPointedAtItWaitsInTheBottomRight() {
        let origin = VisionBubblePlacement.origin(for: nil, size: size, in: bounds)
        XCTAssertEqual(origin.x, 1600 - 360 - 24, accuracy: 0.001)
        XCTAssertEqual(origin.y, 24, accuracy: 0.001)
    }

    // MARK: - One mark at a time

    /// The ring and the measured frame both say "this one", so only the more
    /// precise of the two is drawn. A ring inside the frame it belongs to reads
    /// as two marks disagreeing rather than as one becoming certain — and
    /// nothing fails when both appear, which is why the rule is pinned here.
    func testTheRingRetractsOnceTheMeasuredFrameIsKnown() {
        let point = CGPoint(x: 400, y: 700)
        let frame = CGRect(x: 380, y: 680, width: 60, height: 40)
        XCTAssertNil(VisionPointingOverlay.drawnMark(point: point, frame: frame))
    }

    /// Until the element is known the ring is the only evidence the click was
    /// heard, so it has to be there — the screen doing nothing reads as a miss.
    func testWithNoMeasuredFrameTheRingIsWhatIsDrawn() {
        let point = CGPoint(x: 400, y: 700)
        XCTAssertEqual(
            VisionPointingOverlay.drawnMark(point: point, frame: nil),
            point
        )
    }

    /// The bounds are the visible frame, not the whole display, so a secondary
    /// screen's origin and a reserved menu bar both have to survive the maths.
    func testItRespectsAnOffsetVisibleFrame() {
        let offset = CGRect(x: -1440, y: 120, width: 1440, height: 780)
        let rect = CGRect(
            origin: VisionBubblePlacement.origin(for: nil, size: size, in: offset),
            size: size
        )
        XCTAssertTrue(offset.contains(rect))
        XCTAssertEqual(rect.minY, 144, accuracy: 0.001)
    }
}
