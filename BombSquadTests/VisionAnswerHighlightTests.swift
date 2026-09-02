import XCTest
@testable import Universal_IO

/// The subject mark and the bubble placement are different state machines.
/// These tests pin the mark's resolution ladder without any card-placement
/// input, so a later edit cannot freeze the mark to an early gesture result.
@MainActor
final class VisionAnswerHighlightTests: XCTestCase {
    func testAnswerCandidateReplacesEarlierGestureGeometry() throws {
        let pointed = candidate(id: "pointed", rect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        let answeredRect = CGRect(x: 0.7, y: 0.6, width: 0.2, height: 0.2)
        let answered = candidate(id: "answered", rect: answeredRect)
        let result = visionResult(
            targetCandidateID: "answered",
            annotation: CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1)
        )

        XCTAssertEqual(
            try VisionSession.answerHighlight(
                for: result,
                candidates: [pointed, answered],
                toleratingUnplaceableTarget: true
            ),
            .candidate(index: 1, rect: answeredRect)
        )
    }

    func testAnnotationBecomesTheAnswerFrameWhenNoCandidateWasNamed() throws {
        let box = CGRect(x: 0.25, y: 0.4, width: 0.3, height: 0.2)

        XCTAssertEqual(
            try VisionSession.answerHighlight(
                for: visionResult(targetCandidateID: nil, annotation: box),
                candidates: [],
                toleratingUnplaceableTarget: true
            ),
            .annotation(box)
        )
    }

    func testToleratedUnplaceableCandidateFallsBackToAnnotation() throws {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)

        XCTAssertEqual(
            try VisionSession.answerHighlight(
                for: visionResult(targetCandidateID: "missing", annotation: box),
                candidates: [],
                toleratingUnplaceableTarget: true
            ),
            .annotation(box)
        )
    }

    func testMissingAnswerGeometryIsReportedAsNone() throws {
        XCTAssertEqual(
            try VisionSession.answerHighlight(
                for: visionResult(targetCandidateID: nil, annotation: nil),
                candidates: [],
                toleratingUnplaceableTarget: true
            ),
            .none
        )
    }

    private func candidate(id: String, rect: CGRect) -> VisionObservation.Candidate {
        VisionObservation.Candidate(
            id: id,
            source: "ax",
            role: "Button",
            label: id,
            rect: rect,
            parentLabel: nil,
            states: []
        )
    }

    private func visionResult(
        targetCandidateID: String?,
        annotation: CGRect?
    ) -> VisionResult {
        VisionResult(
            mode: .answer,
            message: "説明",
            observations: [],
            uncertainties: [],
            targetCandidateID: targetCandidateID,
            annotations: annotation.map {
                [VisionAnnotation(id: "subject", kind: "highlight", box: $0, label: "対象")]
            } ?? []
        )
    }
}
