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

    func testContainerSelectionDoesNotCreateSelectionContext() {
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
        XCTAssertFalse(AXFocusLaunchDecision.shouldLookForVisualSelection(in: snapshot))
    }

    func testMissingAXSelectionEnablesBestEffortVisualHint() {
        let snapshot = makeSnapshot(
            selectedText: nil,
            role: "AXWebArea",
            isEditable: false
        )

        XCTAssertTrue(AXFocusLaunchDecision.shouldLookForVisualSelection(in: snapshot))
    }

    func testAccessibilityDenialDoesNotClaimAVisualSelection() {
        let snapshot = AXFocusSnapshot.unavailable(.permissionDenied)

        XCTAssertEqual(AXFocusLaunchDecision.destination(for: snapshot), .vision)
        XCTAssertFalse(AXFocusLaunchDecision.shouldLookForVisualSelection(in: snapshot))
    }

    func testParallelSummonCaptureCanResolveToCompose() {
        XCTAssertTrue(
            AppMode.capturing(returnTo: .idle).canTransition(to: .compose)
        )
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

    func testWebFragmentDoesNotStopBeforeDocumentSelectionAppears() {
        let snapshot = makeSnapshot(selectedText: nil, role: "AXStaticText")
        let fragment = VisionSelectionCandidate(
            directText: "件名",
            role: "AXHeading",
            label: "件名",
            containerFrame: nil,
            selectionFrames: [],
            scope: .ancestor,
            depth: 2,
            pass: 1,
            rangeEvidence: .unavailable,
            isSecure: false
        )

        XCTAssertFalse(AXFocusSnapshotService.hasAuthoritativeSelection(
            candidates: [fragment],
            sawWebArea: true,
            snapshot: snapshot
        ))
    }

    func testWebDocumentSelectionStopsBoundedRetry() {
        let snapshot = makeSnapshot(selectedText: nil, role: "AXStaticText")
        let document = VisionSelectionCandidate(
            directText: "件名と本文の選択全文",
            role: "AXWebArea",
            label: "Gmail",
            containerFrame: nil,
            selectionFrames: [],
            scope: .document,
            depth: 8,
            pass: 2,
            rangeEvidence: .unavailable,
            isSecure: false
        )

        XCTAssertTrue(AXFocusSnapshotService.hasAuthoritativeSelection(
            candidates: [document],
            sawWebArea: true,
            snapshot: snapshot
        ))
    }

    func testSelectedTextBecomesSelectionContext() {
        let snapshot = makeSnapshot(
            selectedText: "選択部分",
            role: "AXStaticText"
        )

        XCTAssertEqual(snapshot.selection?.kind, .text)
        XCTAssertEqual(snapshot.selection?.text, "選択部分")
        XCTAssertEqual(snapshot.selection?.acquisition, .axSelectedText)
    }

    func testSecureSnapshotNeverHasSelectionContext() {
        let snapshot = makeSnapshot(
            selectedText: "secret",
            role: "AXTextField",
            isSecureField: true
        )

        XCTAssertNil(snapshot.selection)
    }

    private func makeSnapshot(
        selectedText: String? = nil,
        role: String? = nil,
        isEditable: Bool = false,
        isSecureField: Bool = false,
        isElementSelected: Bool = false
    ) -> AXFocusSnapshot {
        let text = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection: VisionSelectionContext?
        if !isSecureField, let text, !text.isEmpty {
            selection = VisionSelectionContext(
                kind: .text,
                text: text,
                structures: [],
                frames: [],
                acquisitionCompleteness: .complete,
                acquisition: .axSelectedText,
                captureVisibility: .unknown
            )
        } else {
            selection = nil
        }
        return AXFocusSnapshot(
            selection: selection,
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
