import XCTest
@testable import Universal_IO

/// A selection summon shows the bubble beside the selected text and nothing
/// else: the user pointed by selecting, so the wash has nothing to say and
/// would only take the clicks they still need.
final class SelectionBubblePresentationTests: XCTestCase {
    /// The rule the resign-active question actually turns on. It used to be
    /// answered from the mode's name, which was right only while Vision always
    /// covered the screen — a bare bubble that outlives every other bare bubble
    /// reads as the app failing to notice it was done.
    func testABubbleWithNoOverlayLeavesTheWayComposeDoes() {
        XCTAssertEqual(
            PanelSpec.forMode(.vision, overlayIsPresented: false)?.closesOnResignActive,
            true
        )
        XCTAssertEqual(
            PanelSpec.forMode(.compose, overlayIsPresented: false)?.closesOnResignActive,
            true
        )
    }

    /// While the overlay is up the answer stays no, wash or no wash: another
    /// app can hold frontmost while every click on the covered display still
    /// arrives here, and under guidance clicking the guided app IS the
    /// interaction.
    func testAnOverlayOnScreenSurvivesLosingFrontmost() {
        XCTAssertEqual(
            PanelSpec.forMode(.vision, overlayIsPresented: true)?.closesOnResignActive,
            false
        )
        XCTAssertEqual(
            PanelSpec.forMode(.copilot, overlayIsPresented: true)?.closesOnResignActive,
            false
        )
    }

    func testNoPanelBeforeThereIsASession() {
        XCTAssertNil(PanelSpec.forMode(.idle, overlayIsPresented: false))
        XCTAssertNil(PanelSpec.forMode(.capturing(returnTo: .idle), overlayIsPresented: false))
    }

    /// A selection that crosses lines or nodes has several frames, and the
    /// bubble belongs beside the whole of what the user chose — not beside the
    /// first fragment of it.
    @MainActor
    func testTheBubbleIsPlacedBesideTheWholeSelection() throws {
        let selection = VisionSelectionContext(
            kind: .text,
            text: "選んだ文章",
            structures: [],
            frames: [
                CGRect(x: 100, y: 200, width: 300, height: 20),
                CGRect(x: 100, y: 220, width: 180, height: 20),
            ],
            acquisitionCompleteness: .complete,
            acquisition: .axDocumentSelection,
            captureVisibility: .visible
        )
        let anchor = try XCTUnwrap(
            SessionCoordinator.selectionAnchorFrame(selection)
        )
        // Width and height come from the union; the origin has been flipped
        // into screen coordinates, so only the size is asserted here — the
        // conversion itself is fixed by VisionPointerTests, and this test
        // exists to prove the union happened.
        XCTAssertEqual(anchor.width, 300)
        XCTAssertEqual(anchor.height, 40)
    }

    @MainActor
    func testNoSelectionMeansNoAnchorRatherThanAnEmptyOne() {
        XCTAssertNil(SessionCoordinator.selectionAnchorFrame(nil))
    }
}
