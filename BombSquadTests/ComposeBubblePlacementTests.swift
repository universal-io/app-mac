import XCTest
@testable import Universal_IO

/// The compose bubble's placement rules (2026-08-27): beside the summoning
/// field, at the centre of the working screen when none was measured — where
/// the panel this replaces opened — and wherever the user dragged it, which
/// wins until the next summon.
final class ComposeBubblePlacementTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    private let size = CGSize(width: 380, height: 300)

    func testOpensAtTheCentreWhenNoFieldWasMeasured() {
        let origin = PanelController.bubbleOrigin(
            for: BubbleAnchor(),
            size: size,
            in: bounds
        )
        XCTAssertEqual(origin.x, bounds.midX - size.width / 2)
        XCTAssertEqual(origin.y, bounds.midY - size.height / 2)
    }

    func testOpensBesideTheSummoningField() {
        let field = CGRect(x: 300, y: 500, width: 400, height: 44)
        let origin = PanelController.bubbleOrigin(
            for: BubbleAnchor(frame: field),
            size: size,
            in: bounds
        )
        // The same rule Vision's bubble follows for a measured element…
        XCTAssertEqual(
            origin,
            VisionBubblePlacement.origin(besideFrame: field, size: size, in: bounds)
        )
        // …and never on top of the field it serves: input completion that
        // covers the input is self-defeating.
        XCTAssertFalse(CGRect(origin: origin, size: size).intersects(field))
    }

    func testUserDragWinsOverTheField() {
        var anchor = BubbleAnchor(frame: CGRect(x: 300, y: 500, width: 400, height: 44))
        anchor.userTopLeft = CGPoint(x: 40, y: 900)
        let origin = PanelController.bubbleOrigin(for: anchor, size: size, in: bounds)
        XCTAssertEqual(origin.x, 40)
        XCTAssertEqual(origin.y, 900 - size.height)
    }

    // MARK: - AX frame flip

    func testAXFrameFlipsAgainstThePrimaryScreenTop() {
        // A field whose top edge sits 100pt below the top of a 1080pt-tall
        // primary display, 44pt tall: in Cocoa coordinates its bottom edge is
        // 1080 − (100 + 44) = 936.
        let ax = CGRect(x: 300, y: 100, width: 400, height: 44)
        let flipped = VisionPointerResolver.cocoaGlobalRect(axFrame: ax, mainDisplayHeight: 1080)
        XCTAssertEqual(flipped, CGRect(x: 300, y: 936, width: 400, height: 44))
    }

    func testEmptyOrMissingAXFrameIsNoAnchor() {
        XCTAssertNil(VisionPointerResolver.cocoaGlobalRect(axFrame: nil, mainDisplayHeight: 1080))
        XCTAssertNil(VisionPointerResolver.cocoaGlobalRect(
            axFrame: CGRect(x: 10, y: 10, width: 0, height: 0),
            mainDisplayHeight: 1080
        ))
    }

    // MARK: - The synchronous focus read keeps its geometry

    /// The hold-to-talk and menu-bar summons have no AX snapshot of their own:
    /// their only measurement of the field is this verdict. It carried the
    /// position and size all along while the caller took a Bool from it, which
    /// is why those two summons opened in the centre while the double-tap
    /// opened beside the field (2026-08-27).
    func testFocusVerdictCarriesTheMeasuredFrame() {
        let verdict = SituationalContextService.FocusVerdict(
            isEditable: true,
            matched: "textRole",
            role: "AXTextArea",
            subrole: "",
            size: CGSize(width: 400, height: 44),
            position: CGPoint(x: 300, y: 100)
        )
        XCTAssertEqual(verdict.frame, CGRect(x: 300, y: 100, width: 400, height: 44))
        XCTAssertEqual(
            VisionPointerResolver.cocoaGlobalRect(
                axFrame: verdict.frame,
                mainDisplayHeight: 1080
            ),
            CGRect(x: 300, y: 936, width: 400, height: 44)
        )
    }

    /// Half a rectangle is not a place: an element AX would not fully measure
    /// falls back to the centre rather than to a corner derived from one half.
    func testFocusVerdictWithHalfAMeasurementIsNoFrame() {
        let noSize = SituationalContextService.FocusVerdict(
            isEditable: true,
            matched: "textRole",
            role: "AXTextArea",
            subrole: "",
            size: nil,
            position: CGPoint(x: 300, y: 100)
        )
        let noPosition = SituationalContextService.FocusVerdict(
            isEditable: true,
            matched: "textRole",
            role: "AXTextArea",
            subrole: "",
            size: CGSize(width: 400, height: 44),
            position: nil
        )
        XCTAssertNil(noSize.frame)
        XCTAssertNil(noPosition.frame)
    }
}
