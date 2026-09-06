import XCTest
@testable import Universal_IO

/// The subject mark and the bubble placement are different state machines.
/// These tests pin the mark's resolution ladder without any card-placement
/// input, so a later edit cannot freeze the mark to an early gesture result.
///
/// With one exception, which is the gesture's own: where a ring or a measured
/// tap has already established the place, the answer's frame is taken only if
/// it agrees with that place. A tap nothing could measure has no such place,
/// and there the answer's frame is the only geometry there is.
@MainActor
final class VisionAnswerHighlightTests: XCTestCase {
    /// A tap accessibility could not measure: the answer's frame is the mark.
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

    /// A ring around an area is the subject, whole. The answer may not pick
    /// one element out of it — nor, as happened, one far away from it — and
    /// the stroke stays as the mark.
    func testARegionKeepsItsStrokeWhateverTheAnswerNames() throws {
        let region = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let inside = candidate(id: "inside", rect: CGRect(x: 0.12, y: 0.12, width: 0.05, height: 0.05))
        let far = candidate(id: "debug-navigator", rect: CGRect(x: 0.7, y: 0.6, width: 0.05, height: 0.05))

        for named in ["inside", "debug-navigator"] {
            XCTAssertEqual(
                try VisionSession.answerHighlight(
                    for: visionResult(targetCandidateID: named, annotation: nil),
                    candidates: [inside, far],
                    toleratingUnplaceableTarget: true,
                    keeping: .region(region)
                ),
                .gestureKept,
                "the answer's \(named) replaced the user's ring"
            )
        }
        XCTAssertEqual(
            try VisionSession.answerHighlight(
                for: visionResult(targetCandidateID: nil, annotation: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)),
                candidates: [],
                toleratingUnplaceableTarget: true,
                keeping: .region(region)
            ),
            .gestureKept
        )
    }

    /// A measured element keeps its frame against an answer frame elsewhere,
    /// and yields to one that overlaps it — the same place, or a more specific
    /// control inside it.
    func testAMeasuredElementYieldsOnlyToAnOverlappingFrame() throws {
        let element = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1)
        let within = CGRect(x: 0.45, y: 0.42, width: 0.05, height: 0.05)
        let elsewhere = CGRect(x: 0.05, y: 0.05, width: 0.05, height: 0.05)
        let candidates = [candidate(id: "within", rect: within), candidate(id: "elsewhere", rect: elsewhere)]

        XCTAssertEqual(
            try VisionSession.answerHighlight(
                for: visionResult(targetCandidateID: "within", annotation: nil),
                candidates: candidates,
                toleratingUnplaceableTarget: true,
                keeping: .measured(element)
            ),
            .candidate(index: 0, rect: within)
        )
        XCTAssertEqual(
            try VisionSession.answerHighlight(
                for: visionResult(targetCandidateID: "elsewhere", annotation: nil),
                candidates: candidates,
                toleratingUnplaceableTarget: true,
                keeping: .measured(element)
            ),
            .gestureKept
        )
        XCTAssertEqual(
            try VisionSession.answerHighlight(
                for: visionResult(targetCandidateID: nil, annotation: elsewhere),
                candidates: [],
                toleratingUnplaceableTarget: true,
                keeping: .measured(element)
            ),
            .gestureKept
        )
    }

    /// A guide answer's frame is the next control to press, not a claim about
    /// the gesture. The answer that opens guidance is applied while the
    /// pointing gesture is still bound, and on 2026-09-07 it came back
    /// `gestureKept`: point, ask, and guidance opened with no frame.
    func testAGuideAnswerIsNotBoundByTheGesture() throws {
        let element = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1)
        let elsewhere = CGRect(x: 0.05, y: 0.05, width: 0.05, height: 0.05)
        let candidates = [candidate(id: "elsewhere", rect: elsewhere)]

        XCTAssertEqual(
            try VisionSession.answerHighlight(
                for: visionResult(targetCandidateID: "elsewhere", annotation: nil, mode: .guide),
                candidates: candidates,
                toleratingUnplaceableTarget: false,
                keeping: .measured(element)
            ),
            .candidate(index: 0, rect: elsewhere)
        )
        XCTAssertEqual(
            try VisionSession.answerHighlight(
                for: visionResult(targetCandidateID: "elsewhere", annotation: nil, mode: .guide),
                candidates: candidates,
                toleratingUnplaceableTarget: false,
                keeping: .region(CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
            ),
            .candidate(index: 0, rect: elsewhere)
        )
    }

    /// No frame from the answer is still no frame; the gesture has nothing to
    /// outrank and nothing is counted as kept.
    func testNoAnswerFrameIsNoneEvenUnderAGesture() throws {
        XCTAssertEqual(
            try VisionSession.answerHighlight(
                for: visionResult(targetCandidateID: nil, annotation: nil),
                candidates: [],
                toleratingUnplaceableTarget: true,
                keeping: .region(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
            ),
            .none
        )
    }

    /// Which gestures bind: a measured tap and a ring do; a tap nothing could
    /// measure does not. Read from the session, which is where `apply` reads it.
    func testTheSessionBindsMeasuredTapsAndRegionsOnly() {
        let session = VisionSession(
            attachment: attachment(),
            selection: nil,
            client: nil
        )
        XCTAssertNil(session.gestureBound, "a fresh session bound something")

        let hit = candidate(id: "hit", rect: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1))
        session.beginPointing()
        session.point(
            pointer: VisionPointer(kind: .point(CGPoint(x: 0.25, y: 0.25)), stroke: nil),
            capture: attachment(), candidates: [hit], diagnostics: nil, hit: hit, placement: .measured
        )
        XCTAssertEqual(session.gestureBound, .measured(hit.rect!))

        let region = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        session.beginPointing()
        session.point(
            pointer: VisionPointer(kind: .region(region), stroke: nil),
            capture: attachment(), candidates: [hit], diagnostics: nil, hit: nil, placement: .region
        )
        XCTAssertEqual(session.gestureBound, .region(region))

        session.beginPointing()
        session.point(
            pointer: VisionPointer(kind: .point(CGPoint(x: 0.9, y: 0.9)), stroke: nil),
            capture: attachment(), candidates: [hit], diagnostics: nil, hit: nil, placement: .unresolved
        )
        XCTAssertNil(session.gestureBound, "an unmeasured tap bound the answer's frame")
    }

    private func attachment() -> ScreenshotAttachment {
        ScreenshotAttachment(
            url: URL(fileURLWithPath: "/tmp/vision-answer-highlight-test.png"),
            pixelWidth: 800,
            pixelHeight: 600,
            captureScope: .display,
            captureRect: CGRect(x: 0, y: 0, width: 800, height: 600)
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
        annotation: CGRect?,
        mode: VisionResult.Mode = .answer
    ) -> VisionResult {
        VisionResult(
            mode: mode,
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
