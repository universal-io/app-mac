import XCTest
@testable import Universal_IO

/// The rules that decide when guidance reads the screen again, and how a frame
/// follows its element between readings. Written from the 2026-09-03 field run
/// where seven of ten steps dropped a click and a frame stayed on a button that
/// had already gone.
final class GuidanceTriggerTests: XCTestCase {

    // MARK: - What a click means

    func testAClickThatLandsInATextInputDefers() {
        for role in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"] {
            XCTAssertEqual(GuidanceTrigger.clickKind(focusedRole: role), .defer, role)
        }
    }

    func testAClickOnAControlAdvances() {
        for role in ["AXButton", "AXLink", "AXRadioButton", "AXCheckBox", "AXWebArea", "AXStaticText"] {
            XCTAssertEqual(GuidanceTrigger.clickKind(focusedRole: role), .advance, role)
        }
        // No focus could be read: the click still counts. Deferring on a guess
        // would leave the user waiting for a pause that never comes.
        XCTAssertEqual(GuidanceTrigger.clickKind(focusedRole: nil), .advance)
    }

    // MARK: - Acting while a step is running

    func testNothingRunningStartsAStep() {
        XCTAssertEqual(
            GuidanceTrigger.disposition(stepRunning: false, stepCaptured: false, questionOpen: false),
            .start
        )
    }

    /// Before the capture, the act will be in the picture the step is about to
    /// take. Dropping it loses nothing.
    func testAnActBeforeTheCaptureIsFoldedIntoTheRunningStep() {
        XCTAssertEqual(
            GuidanceTrigger.disposition(stepRunning: true, stepCaptured: false, questionOpen: false),
            .fold(into: .runningStep)
        )
    }

    /// After the capture, the step is judging a screen the user has left. This
    /// is the case the field run hit six times out of seven.
    func testAnActAfterTheCaptureSupersedesTheRunningStep() {
        XCTAssertEqual(
            GuidanceTrigger.disposition(stepRunning: true, stepCaptured: true, questionOpen: false),
            .supersede
        )
    }

    func testAnOpenTypedQuestionStillAbsorbsTheAct() {
        XCTAssertEqual(
            GuidanceTrigger.disposition(stepRunning: false, stepCaptured: false, questionOpen: true),
            .fold(into: .openQuestion)
        )
        XCTAssertEqual(
            GuidanceTrigger.disposition(stepRunning: true, stepCaptured: true, questionOpen: true),
            .fold(into: .openQuestion)
        )
    }

    // MARK: - A frame following its element

    private let capture = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    /// The rect form must agree with the point form and with the way back out:
    /// a frame normalised here and projected by `screenLocalRect` lands where
    /// `cocoaGlobalRect` puts the same AX frame.
    func testANormalizedFrameProjectsBackOntoTheScreen() throws {
        let axFrame = CGRect(x: 56, y: 1009, width: 256, height: 36)
        let normalized = try XCTUnwrap(VisionPointerResolver.normalized(axFrame, within: capture))
        XCTAssertEqual(normalized.minX, 56 / 1728, accuracy: 1e-9)
        XCTAssertEqual(normalized.minY, 1009 / 1117, accuracy: 1e-9)

        let projected = VisionPointerResolver.screenLocalRect(
            normalized: normalized,
            captureRect: capture,
            mainDisplayHeight: 1117,
            screenFrame: capture
        )
        let expected = try XCTUnwrap(
            VisionPointerResolver.cocoaGlobalRect(axFrame: axFrame, mainDisplayHeight: 1117)
        )
        XCTAssertEqual(projected.minX, expected.minX, accuracy: 1e-6)
        XCTAssertEqual(projected.minY, expected.minY, accuracy: 1e-6)
        XCTAssertEqual(projected.width, expected.width, accuracy: 1e-6)
        XCTAssertEqual(projected.height, expected.height, accuracy: 1e-6)
    }

    /// Scrolled out of the capture entirely: no frame, rather than a frame
    /// clamped to the edge claiming the element is there.
    func testAnElementOutsideTheCaptureHasNoFrame() {
        XCTAssertNil(VisionPointerResolver.normalized(
            CGRect(x: 56, y: 1300, width: 256, height: 36), within: capture
        ))
        XCTAssertNil(VisionPointerResolver.normalized(
            CGRect(x: 56, y: -100, width: 256, height: 36), within: capture
        ))
    }

    /// Half off the bottom edge: the visible half is framed, the rest is not
    /// pretended to be on screen.
    func testAPartlyVisibleElementIsClippedToTheCapture() throws {
        let normalized = try XCTUnwrap(VisionPointerResolver.normalized(
            CGRect(x: 100, y: 1100, width: 200, height: 40), within: capture
        ))
        XCTAssertEqual(normalized.height * capture.height, 17, accuracy: 1e-6)
        XCTAssertEqual(normalized.maxY, 1, accuracy: 1e-9)
    }

    func testAnEmptyCaptureCannotPlaceAnything() {
        XCTAssertNil(VisionPointerResolver.normalized(
            CGRect(x: 1, y: 1, width: 1, height: 1), within: .zero
        ))
    }
}
