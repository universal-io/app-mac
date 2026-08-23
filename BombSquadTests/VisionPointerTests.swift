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

    /// A pointing turn must be an ordinary Vision turn plus one field. The
    /// selection extension is held to the same rule, for the same reason: the
    /// moment a second thing changes, a difference in the answer stops being
    /// attributable to the gesture.
    func testPointingRequestDiffersOnlyByThePointerField() throws {
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

        XCTAssertNotNil(pointerPayload)
        XCTAssertTrue(NSDictionary(dictionary: ordinary).isEqual(to: pointing))
        XCTAssertNil(ordinary["pointer"])
        // Annotations stay off: this client has AX-measured rectangles, and
        // asking for the model's estimate as well would change the prompt and
        // the schema for every other turn.
        XCTAssertNil(ordinary["wants_annotations"])
        XCTAssertNil(pointerPayload as? Bool)
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
