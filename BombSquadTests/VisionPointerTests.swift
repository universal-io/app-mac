import XCTest
@testable import Universal_IO

final class VisionPointerTests: XCTestCase {
    // MARK: - Coordinate conversion

    func testMainDisplayPointConvertsToCaptureNormalizedSpace() throws {
        // 1920x1080 main display, captured whole. A click 480 points from the
        // left and 270 points up from the bottom is a quarter in from the left
        // and three quarters down.
        let global = VisionPointerResolver.globalCGPoint(
            cocoaGlobal: CGPoint(x: 480, y: 270),
            mainDisplayHeight: 1080
        )
        XCTAssertEqual(global.y, 810, accuracy: 0.001)

        let normalized = try XCTUnwrap(
            VisionPointerResolver.normalized(
                global,
                within: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            )
        )
        XCTAssertEqual(normalized.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(normalized.y, 0.75, accuracy: 0.0001)
    }

    /// The offset bug this project has already paid for twice: a display placed
    /// left of and above the main one has negative origins, and a conversion
    /// that forgets the capture's own origin lands the mark on the wrong
    /// monitor.
    func testSecondaryDisplayAboveAndLeftKeepsItsOffset() throws {
        // Main display 1920x1080 at CG (0,0). Secondary 1440x900 sits to its
        // left and 200 points higher, so in CG it starts at (-1440, -200).
        // In Cocoa global that same top-left corner is y = 1080 + 200 = 1280.
        let global = VisionPointerResolver.globalCGPoint(
            cocoaGlobal: CGPoint(x: -720, y: 830),
            mainDisplayHeight: 1080
        )
        XCTAssertEqual(global.x, -720, accuracy: 0.001)
        XCTAssertEqual(global.y, 250, accuracy: 0.001)

        let normalized = try XCTUnwrap(
            VisionPointerResolver.normalized(
                global,
                within: CGRect(x: -1440, y: -200, width: 1440, height: 900)
            )
        )
        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.0001)
    }

    func testPointOnAnUncapturedDisplayIsRejectedRatherThanClamped() {
        // The capture covers the main display only; the click happened on the
        // one beside it. Clamping would answer about the captured edge, which
        // the user never pointed at.
        let global = VisionPointerResolver.globalCGPoint(
            cocoaGlobal: CGPoint(x: 2400, y: 500),
            mainDisplayHeight: 1080
        )
        XCTAssertNil(
            VisionPointerResolver.normalized(
                global,
                within: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            )
        )
    }

    func testRegionCaptureNormalizesAgainstTheRegionNotTheDisplay() throws {
        // A region capture's rect is the region, so the same screen point is a
        // different fraction. Normalizing against the display here is the
        // mistake this test exists to catch.
        let global = VisionPointerResolver.globalCGPoint(
            cocoaGlobal: CGPoint(x: 700, y: 700),
            mainDisplayHeight: 1080
        )
        XCTAssertEqual(global.y, 380, accuracy: 0.001)

        let normalized = try XCTUnwrap(
            VisionPointerResolver.normalized(
                global,
                within: CGRect(x: 600, y: 300, width: 400, height: 200)
            )
        )
        XCTAssertEqual(normalized.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(normalized.y, 0.4, accuracy: 0.0001)
    }

    func testDegenerateCaptureRectIsRejected() {
        XCTAssertNil(
            VisionPointerResolver.normalized(
                CGPoint(x: 10, y: 10),
                within: CGRect(x: 0, y: 0, width: 0, height: 0)
            )
        )
    }

    // MARK: - Back onto the screen

    /// The round trip has to close. A point converted in and a rectangle
    /// converted out must agree about where the thing is, or the frame lands
    /// beside the mark and the user is told to look at the wrong control.
    func testAPointConvertedInComesBackToTheSamePlaceOnScreen() throws {
        let captureRect = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let screenFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let clickedScreenLocal = CGPoint(x: 400, y: 700)

        let normalized = try XCTUnwrap(
            VisionPointerResolver.normalized(
                VisionPointerResolver.globalCGPoint(
                    cocoaGlobal: clickedScreenLocal,
                    mainDisplayHeight: 1000
                ),
                within: captureRect
            )
        )
        // A candidate exactly one point across, centred on the click.
        let back = VisionPointerResolver.screenLocalRect(
            normalized: CGRect(x: normalized.x, y: normalized.y, width: 0, height: 0),
            captureRect: captureRect,
            mainDisplayHeight: 1000,
            screenFrame: screenFrame
        )
        XCTAssertEqual(back.minX, clickedScreenLocal.x, accuracy: 0.001)
        XCTAssertEqual(back.minY, clickedScreenLocal.y, accuracy: 0.001)
    }

    func testARectangleKeepsItsHeightAndLandsWithItsTopEdgeUp() {
        // Top-left origin going in, bottom-left coming out: a band across the
        // top of the capture must come out near the top of the screen.
        let rect = VisionPointerResolver.screenLocalRect(
            normalized: CGRect(x: 0.1, y: 0, width: 0.2, height: 0.05),
            captureRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            mainDisplayHeight: 1000,
            screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        XCTAssertEqual(rect.minX, 160, accuracy: 0.001)
        XCTAssertEqual(rect.width, 320, accuracy: 0.001)
        XCTAssertEqual(rect.height, 50, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 1000, accuracy: 0.001)
    }

    func testASecondaryDisplaysOffsetIsSubtractedOnTheWayOut() {
        // Secondary 1440x900 left of and above the main display: CG origin
        // (-1440, -200), so Cocoa origin y = 1080 - 700 = 380.
        let rect = VisionPointerResolver.screenLocalRect(
            normalized: CGRect(x: 0.5, y: 0.5, width: 0, height: 0),
            captureRect: CGRect(x: -1440, y: -200, width: 1440, height: 900),
            mainDisplayHeight: 1080,
            screenFrame: CGRect(x: -1440, y: 380, width: 1440, height: 900)
        )
        // Centre of that display, expressed inside a window covering it.
        XCTAssertEqual(rect.minX, 720, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 450, accuracy: 0.001)
    }

    // MARK: - Hit test

    func testSmallestContainingCandidateWins() throws {
        let window = candidate(id: "window", rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        let toolbar = candidate(id: "toolbar", rect: CGRect(x: 0, y: 0, width: 1, height: 0.1))
        let button = candidate(id: "button", rect: CGRect(x: 0.4, y: 0.02, width: 0.08, height: 0.05))

        let hit = try XCTUnwrap(
            VisionPointerResolver.candidate(
                at: CGPoint(x: 0.44, y: 0.04),
                in: [window, toolbar, button]
            )
        )
        XCTAssertEqual(hit.id, "button")
    }

    /// AX candidates cover thirteen operable roles only, so body text, images,
    /// graphs and canvases produce no hit at all. That is a normal outcome and
    /// must not read as a failure: the answer still comes from the burned mark.
    func testNoCandidateUnderThePointIsNotAnError() {
        let button = candidate(id: "button", rect: CGRect(x: 0.4, y: 0.02, width: 0.08, height: 0.05))
        XCTAssertNil(
            VisionPointerResolver.candidate(at: CGPoint(x: 0.9, y: 0.9), in: [button])
        )
    }

    func testCandidatesWithoutRectanglesAreNeverHit() {
        let rectless = VisionObservation.Candidate(
            id: "rectless",
            source: "ax",
            role: "Button",
            label: "Chrome gave us no frame",
            rect: nil,
            parentLabel: nil,
            states: []
        )
        XCTAssertNil(
            VisionPointerResolver.candidate(at: CGPoint(x: 0.5, y: 0.5), in: [rectless])
        )
    }

    // MARK: - Gestures

    func testAPressThatStayedPutIsATap() throws {
        let gesture = VisionPointerResolver.gesture(from: [
            CGPoint(x: 400, y: 700),
            CGPoint(x: 402, y: 703),
            CGPoint(x: 401, y: 701),
        ])
        XCTAssertEqual(gesture, .point(CGPoint(x: 400, y: 700)))
    }

    /// A ring ends near where it began, so distance from the start would call a
    /// finished circle a click. The path's own bounds are what separates them.
    func testACircleBackToItsStartIsStillAnEnclosure() throws {
        let radius: CGFloat = 40
        let centre = CGPoint(x: 500, y: 500)
        let circle = (0...36).map { step -> CGPoint in
            let angle = CGFloat(step) * .pi / 18
            return CGPoint(
                x: centre.x + cos(angle) * radius,
                y: centre.y + sin(angle) * radius
            )
        }
        guard case .region(let path) = VisionPointerResolver.gesture(from: circle) else {
            return XCTFail("a drawn circle was read as a tap")
        }
        XCTAssertEqual(path.count, circle.count)
    }

    /// Dragging along a line of text is how somebody says "this line". Judging
    /// intent by whether the shape looks deliberate would reject it.
    func testAStraightDragIsAnEnclosureNotAStrayClick() throws {
        let gesture = VisionPointerResolver.gesture(from: [
            CGPoint(x: 300, y: 500),
            CGPoint(x: 380, y: 500),
            CGPoint(x: 460, y: 500),
        ])
        guard case .region = gesture else {
            return XCTFail("a deliberate horizontal stroke was read as a tap")
        }
    }

    func testAnEmptyPathMeansNothing() {
        XCTAssertNil(VisionPointerResolver.gesture(from: []))
    }

    /// The Gateway rejects a zero-area region as a click that dragged nowhere —
    /// right for a stray event, wrong for the stroke that says "this line". The
    /// degenerate axis opens around its own centre instead.
    func testAFlatStrokeBecomesARegionTheGatewayAccepts() throws {
        let region = try XCTUnwrap(VisionPointerResolver.normalizedRegion(from: [
            CGPoint(x: 0.20, y: 0.50),
            CGPoint(x: 0.60, y: 0.50),
        ]))
        XCTAssertGreaterThan(region.height, 0)
        XCTAssertEqual(region.midY, 0.50, accuracy: 0.0001)
        XCTAssertEqual(region.minX, 0.20, accuracy: 0.0001)
        XCTAssertEqual(region.width, 0.40, accuracy: 0.0001)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(region))
    }

    /// Opening a flat stroke drawn along the very edge must not push the
    /// rectangle outside the image, which the contract refuses.
    func testAStrokeAlongTheEdgeStaysInsideTheImage() throws {
        for y in [CGFloat(0), CGFloat(1)] {
            let region = try XCTUnwrap(VisionPointerResolver.normalizedRegion(from: [
                CGPoint(x: 0.1, y: y),
                CGPoint(x: 0.4, y: y),
            ]))
            XCTAssertTrue(
                CGRect(x: 0, y: 0, width: 1, height: 1).contains(region),
                "region left the image for a stroke at y=\(y): \(region)"
            )
            XCTAssertGreaterThan(region.height, 0)
        }
    }

    /// Every point of the path can fall outside the captured display, which
    /// leaves nothing to enclose. Saying so beats sending a rectangle nobody
    /// drew.
    func testAPathWithNothingLeftIsNoRegion() {
        XCTAssertNil(VisionPointerResolver.normalizedRegion(from: []))
        XCTAssertNil(VisionPointerResolver.normalizedRegion(from: [CGPoint(x: 0.5, y: 0.5)]))
    }

    // MARK: - Wire format

    func testPointWirePayloadMatchesTheGatewayContract() throws {
        let payload = VisionPointer(kind: .point(CGPoint(x: 0.25, y: 0.75))).wirePayload
        XCTAssertEqual(payload["kind"] as? String, "point")
        let point = try XCTUnwrap(payload["point"] as? [String: Double])
        XCTAssertEqual(point["x"], 0.25)
        XCTAssertEqual(point["y"], 0.75)
        XCTAssertNil(payload["region"])
    }

    func testRegionWirePayloadUsesTheContractsShortKeys() throws {
        let payload = VisionPointer(
            kind: .region(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        ).wirePayload
        XCTAssertEqual(payload["kind"] as? String, "region")
        let region = try XCTUnwrap(payload["region"] as? [String: Double])
        XCTAssertEqual(region["x"], 0.1)
        XCTAssertEqual(region["y"], 0.2)
        XCTAssertEqual(region["w"], 0.3)
        XCTAssertEqual(region["h"], 0.4)
        XCTAssertNil(payload["point"])
    }

    // MARK: - Request contract

    /// A pointing turn is an ordinary Vision turn plus the gesture and a request
    /// for a box — and nothing else. Those two travel together on purpose: the
    /// box is what lets the frame land on whatever the answer turned out to be
    /// about, which is the only way the mark and the sentence can be seen to
    /// agree. Anything beyond these two changing would make a difference in the
    /// answer unattributable, which is the same rule the selection extension is
    /// held to.
    func testPointingRequestDiffersOnlyByTheGestureAndItsBox() throws {
        let attachment = ScreenshotAttachment(
            url: URL(fileURLWithPath: "/tmp/pointer.png"),
            pixelWidth: 800,
            pixelHeight: 600,
            captureScope: .display,
            captureRect: CGRect(x: 100, y: 200, width: 400, height: 300)
        )
        let candidates = [candidate(id: "ax:1", rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1))]

        let ordinary = GatewayVisionClient.requestInput(
            attachment: attachment,
            imageBase64: "same-image",
            mediaType: "image/png",
            question: nil,
            turns: [],
            candidates: candidates
        )
        var pointing = GatewayVisionClient.requestInput(
            attachment: attachment,
            imageBase64: "same-image",
            mediaType: "image/png",
            question: nil,
            turns: [],
            candidates: candidates,
            pointer: VisionPointer(kind: .point(CGPoint(x: 0.5, y: 0.5)))
        )
        let pointerPayload = pointing.removeValue(forKey: "pointer")
        let wantsAnnotations = pointing.removeValue(forKey: "wants_annotations")

        XCTAssertNotNil(pointerPayload)
        XCTAssertEqual(wantsAnnotations as? Bool, true)
        XCTAssertTrue(NSDictionary(dictionary: ordinary).isEqual(to: pointing))
        XCTAssertNil(ordinary["pointer"])
        // An ordinary turn's prompt and schema stay byte-identical to what every
        // shipped client already gets: asking for boxes is what changes them, and
        // only a pointing turn asks.
        XCTAssertNil(ordinary["wants_annotations"])
    }

    /// The hand-drawn path shapes the burned mark and must never reach the
    /// wire — the contract carries a point or a rectangle and nothing else.
    func testTheHandDrawnStrokeIsNeverSent() throws {
        let payload = VisionPointer(
            kind: .region(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            stroke: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.3, y: 0.2)]
        ).wirePayload
        XCTAssertEqual(payload.keys.sorted(), ["kind", "region"])
    }

    /// The mark says where; the hit id says what the OS measured there. It
    /// names an entry in the candidates list that travels with the same
    /// request, so the Gateway can pin the model to the element under the mark
    /// rather than a lookalike elsewhere (2026-08-24: GitLab's two "+" buttons
    /// traded places while the burned mark sat exactly on the clicked one).
    func testTheMeasuredHitTravelsInsideThePointer() throws {
        let payload = VisionPointer(
            kind: .point(CGPoint(x: 0.87, y: 0.16)),
            hitCandidateID: "ax:7"
        ).wirePayload
        XCTAssertEqual(payload["hit_candidate_id"] as? String, "ax:7")
    }

    /// No hit is not an empty hit: the key must be absent so the Gateway's
    /// validator never sees an empty string where an id was promised.
    func testWithoutAHitThePointerCarriesNoHitKey() throws {
        let payload = VisionPointer(kind: .point(CGPoint(x: 0.5, y: 0.5))).wirePayload
        XCTAssertEqual(payload.keys.sorted(), ["kind", "point"])
    }

    // MARK: - Helpers

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
}
