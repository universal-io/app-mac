import XCTest
@testable import Universal_IO

final class AXFocusSnapshotTests: XCTestCase {
    func testSelectedTextTakesPriorityOverEditableField() {
        let snapshot = makeSnapshot(selectedText: "選択部分", isEditable: true)

        XCTAssertEqual(
            AXFocusLaunchDecision.destination(for: snapshot),
            .focusedVision
        )
    }

    func testEmptySelectionUsesComposeForEditableField() {
        let snapshot = makeSnapshot(selectedText: " \n\t", isEditable: true)

        XCTAssertEqual(AXFocusLaunchDecision.destination(for: snapshot), .compose)
    }

    func testEmptySelectionUsesVisionForNonEditableElement() {
        let snapshot = makeSnapshot(selectedText: nil, isEditable: false)

        XCTAssertEqual(AXFocusLaunchDecision.destination(for: snapshot), .vision)
    }

    func testMeaningfulSelectedElementUsesFocusedVisionWithoutText() {
        let snapshot = makeSnapshot(
            selectedText: nil,
            role: "AXButton",
            isElementSelected: true
        )

        XCTAssertEqual(
            AXFocusLaunchDecision.destination(for: snapshot),
            .focusedVision
        )
    }

    func testContainerSelectionDoesNotCreateFocusTarget() {
        let snapshot = makeSnapshot(
            selectedText: nil,
            role: "AXWebArea",
            isElementSelected: true
        )

        XCTAssertEqual(AXFocusLaunchDecision.destination(for: snapshot), .vision)
    }

    func testSecureFieldAlwaysFallsBackToVision() {
        let snapshot = makeSnapshot(
            selectedText: "must never be retained",
            role: "AXTextField",
            isEditable: true,
            isSecureField: true,
            isElementSelected: true
        )

        XCTAssertEqual(AXFocusLaunchDecision.destination(for: snapshot), .vision)
    }

    func testColdTreeRetriesWhileFocusIsUnavailable() {
        XCTAssertTrue(AXFocusSnapshotRetryPolicy.shouldRetry(
            pass: 1,
            maxPasses: 6,
            beforeExpiry: true,
            hasSelection: false,
            hasFocusedElement: false,
            sawWebArea: false,
            visitedNodes: 0,
            previousVisitedNodes: 0
        ))
    }

    func testGrowingChromiumTreeRetries() {
        XCTAssertTrue(AXFocusSnapshotRetryPolicy.shouldRetry(
            pass: 2,
            maxPasses: 6,
            beforeExpiry: true,
            hasSelection: false,
            hasFocusedElement: true,
            sawWebArea: true,
            visitedNodes: 150,
            previousVisitedNodes: 100
        ))
    }

    func testRetryStopsAtExpiryAndPassLimit() {
        XCTAssertFalse(AXFocusSnapshotRetryPolicy.shouldRetry(
            pass: 2,
            maxPasses: 6,
            beforeExpiry: false,
            hasSelection: false,
            hasFocusedElement: false,
            sawWebArea: false,
            visitedNodes: 0,
            previousVisitedNodes: 0
        ))
        XCTAssertFalse(AXFocusSnapshotRetryPolicy.shouldRetry(
            pass: 6,
            maxPasses: 6,
            beforeExpiry: true,
            hasSelection: false,
            hasFocusedElement: false,
            sawWebArea: true,
            visitedNodes: 200,
            previousVisitedNodes: 100
        ))
    }

    func testRetryStopsAsSoonAsSelectionAppears() {
        XCTAssertFalse(AXFocusSnapshotRetryPolicy.shouldRetry(
            pass: 1,
            maxPasses: 6,
            beforeExpiry: true,
            hasSelection: true,
            hasFocusedElement: true,
            sawWebArea: true,
            visitedNodes: 200,
            previousVisitedNodes: 100
        ))
    }

    private func makeSnapshot(
        selectedText: String? = nil,
        role: String? = nil,
        isEditable: Bool = false,
        isSecureField: Bool = false,
        isElementSelected: Bool = false
    ) -> AXFocusSnapshot {
        AXFocusSnapshot(
            selectedText: selectedText,
            role: role,
            label: nil,
            frame: nil,
            isEditable: isEditable,
            isSecureField: isSecureField,
            isElementSelected: isElementSelected,
            status: .complete,
            collectionPasses: 1
        )
    }
}
