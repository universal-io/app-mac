import XCTest
@testable import Universal_IO

final class AXFocusSnapshotTests: XCTestCase {
    func testSelectedTextTakesPriorityOverEditableField() {
        let snapshot = makeSnapshot(selectedText: "選択部分", isEditable: true)

        XCTAssertEqual(
            AXFocusLaunchDecision.destination(for: snapshot),
            .vision
        )
        XCTAssertEqual(
            AXFocusLaunchDecision.selectionExtension(for: snapshot)?.text,
            "選択部分"
        )
    }

    func testEmptySelectionUsesComposeForEditableField() {
        let snapshot = makeSnapshot(selectedText: " \n\t", isEditable: true)

        XCTAssertEqual(AXFocusLaunchDecision.destination(for: snapshot), .compose)
        XCTAssertNil(AXFocusLaunchDecision.selectionExtension(for: snapshot))
    }

    func testEmptySelectionUsesVisionForNonEditableElement() {
        let snapshot = makeSnapshot(selectedText: nil, isEditable: false)

        XCTAssertEqual(AXFocusLaunchDecision.destination(for: snapshot), .vision)
        XCTAssertNil(AXFocusLaunchDecision.selectionExtension(for: snapshot))
    }

    /// A sidebar row, tab, or list item the app reports as its current item is
    /// not something the user chose to ask about, however rich its structure is.
    func testCurrentItemWithoutSelectedTextIsNotASelection() {
        let snapshot = makeSnapshot(
            selectedText: nil,
            role: "AXRow",
            label: "現在のサイドバー項目"
        )

        XCTAssertNil(AXFocusLaunchDecision.selectionExtension(for: snapshot))
        XCTAssertEqual(AXFocusLaunchDecision.destination(for: snapshot), .vision)
    }

    func testCurrentItemInsideAnEditableFieldOpensCompose() {
        let snapshot = makeSnapshot(
            selectedText: nil,
            role: "AXTextField",
            label: "検索",
            isEditable: true
        )

        XCTAssertNil(AXFocusLaunchDecision.selectionExtension(for: snapshot))
        XCTAssertEqual(AXFocusLaunchDecision.destination(for: snapshot), .compose)
    }

    func testSecureFieldAlwaysFallsBackToVision() {
        let snapshot = makeSnapshot(
            selectedText: "must never be retained",
            role: "AXTextField",
            isEditable: true,
            isSecureField: true
        )

        XCTAssertEqual(AXFocusLaunchDecision.destination(for: snapshot), .vision)
        XCTAssertNil(AXFocusLaunchDecision.selectionExtension(for: snapshot))
    }

    /// Every way acquisition can fail. None of them is evidence that the user
    /// selected something, so each one is an ordinary Vision summon.
    func testUnresolvedCapturesNeverClaimASelection() {
        let statuses: [AXFocusSnapshot.CaptureStatus] = [
            .complete, .permissionDenied, .invalidTarget,
            .noFocusedElement, .timedOut, .invalidatedElement,
        ]

        for status in statuses {
            let snapshot = AXFocusSnapshot.unavailable(status)

            XCTAssertNil(
                AXFocusLaunchDecision.selectionExtension(for: snapshot),
                "\(status) must not produce a selection"
            )
            XCTAssertEqual(
                AXFocusLaunchDecision.destination(for: snapshot),
                .vision,
                "\(status) must stay on ordinary Vision"
            )
        }
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
            hasPartialSelectionEvidence: false,
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
            hasPartialSelectionEvidence: false,
            visitedNodes: 150,
            previousVisitedNodes: 100
        ))
    }

    /// The most common summon of all: a settled browser page with nothing
    /// selected. One extra pass covers a tree that may still be cold; after
    /// that, waiting cannot change the answer and only delays the panel.
    func testSettledPageWithoutSelectionEvidenceStopsEarly() {
        func retry(pass: Int) -> Bool {
            AXFocusSnapshotRetryPolicy.shouldRetry(
                pass: pass,
                maxPasses: 6,
                beforeExpiry: true,
                hasSelection: false,
                hasFocusedElement: true,
                sawWebArea: true,
                hasPartialSelectionEvidence: false,
                visitedNodes: 200,
                previousVisitedNodes: 200
            )
        }

        XCTAssertTrue(retry(pass: 1))
        XCTAssertFalse(retry(pass: 2))
        XCTAssertFalse(retry(pass: 5))
    }

    func testFragmentsWithoutDocumentSelectionKeepRetrying() {
        XCTAssertTrue(AXFocusSnapshotRetryPolicy.shouldRetry(
            pass: 3,
            maxPasses: 6,
            beforeExpiry: true,
            hasSelection: false,
            hasFocusedElement: true,
            sawWebArea: true,
            hasPartialSelectionEvidence: true,
            visitedNodes: 200,
            previousVisitedNodes: 200
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
            hasPartialSelectionEvidence: false,
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
            hasPartialSelectionEvidence: true,
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
            hasPartialSelectionEvidence: true,
            visitedNodes: 200,
            previousVisitedNodes: 100
        ))
    }

    func testWebFragmentDoesNotStopBeforeDocumentSelectionAppears() {
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
            sawWebArea: true
        ))
        XCTAssertTrue(AXFocusSnapshotService.hasPartialSelectionEvidence(
            candidates: [fragment],
            sawWebArea: true
        ))
    }

    func testWebDocumentSelectionStopsBoundedRetry() {
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
            sawWebArea: true
        ))
        XCTAssertFalse(AXFocusSnapshotService.hasPartialSelectionEvidence(
            candidates: [document],
            sawWebArea: true
        ))
    }

    func testNoCandidatesIsNotPartialEvidence() {
        XCTAssertFalse(AXFocusSnapshotService.hasPartialSelectionEvidence(
            candidates: [],
            sawWebArea: true
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

    func testSecureDescendantPreventsDocumentSelectionRead() {
        XCTAssertFalse(
            AXFocusSnapshotService.shouldReadDocumentSelection(sawSecureDescendant: true)
        )
        XCTAssertTrue(
            AXFocusSnapshotService.shouldReadDocumentSelection(sawSecureDescendant: false)
        )
    }

    /// Chrome makes the document itself the focused element and exposes the
    /// selection there. Treating a web area as an ordinary ancestor — or
    /// skipping it — threw away a selection AX had already handed over.
    func testWebAreaIsAlwaysDocumentScopeWhereverItAppears() {
        XCTAssertEqual(
            AXFocusSnapshotService.selectionScope(role: "AXWebArea", isFocusedElement: true),
            .document
        )
        XCTAssertEqual(
            AXFocusSnapshotService.selectionScope(role: "AXWebArea", isFocusedElement: false),
            .document
        )
        XCTAssertEqual(
            AXFocusSnapshotService.selectionScope(role: "AXTextArea", isFocusedElement: true),
            .focusedElement
        )
        XCTAssertEqual(
            AXFocusSnapshotService.selectionScope(role: "AXGroup", isFocusedElement: false),
            .ancestor
        )
    }

    private func makeSnapshot(
        selectedText: String? = nil,
        role: String? = nil,
        label: String? = nil,
        isEditable: Bool = false,
        isSecureField: Bool = false
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
            label: label,
            frame: nil,
            isEditable: isEditable,
            isSecureField: isSecureField,
            status: .complete,
            collectionPasses: 1
        )
    }
}
