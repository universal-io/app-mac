import XCTest
@testable import Universal_IO

final class VisionFocusTargetTests: XCTestCase {
    func testSelectedTextWirePayloadUsesCapturePixelCoordinates() throws {
        let snapshot = AXFocusSnapshot(
            selectedText: "選択部分",
            role: "AXStaticText",
            label: "本文",
            frame: CGRect(x: 150, y: 250, width: 100, height: 50),
            isEditable: false,
            isSecureField: false,
            isElementSelected: false,
            status: .complete,
            collectionPasses: 1
        )
        let target = try XCTUnwrap(VisionFocusTarget.from(snapshot: snapshot))
        let payload = try XCTUnwrap(target.wirePayload(for: attachment()))
        let frame = try XCTUnwrap(payload["frame"] as? [String: Double])

        XCTAssertEqual(payload["kind"] as? String, "selected_text")
        XCTAssertEqual(payload["source"] as? String, "ax_selected_text")
        XCTAssertEqual(payload["text"] as? String, "選択部分")
        XCTAssertEqual(payload["truncated"] as? Bool, false)
        XCTAssertEqual(frame["x"], 100)
        XCTAssertEqual(frame["y"], 100)
        XCTAssertEqual(frame["width"], 200)
        XCTAssertEqual(frame["height"], 100)
    }

    func testFrameIsClippedToCaptureBeforeConversion() throws {
        let snapshot = AXFocusSnapshot(
            selectedText: "partly visible",
            role: "AXStaticText",
            label: nil,
            frame: CGRect(x: 50, y: 150, width: 100, height: 100),
            isEditable: false,
            isSecureField: false,
            isElementSelected: false,
            status: .complete,
            collectionPasses: 1
        )
        let target = try XCTUnwrap(VisionFocusTarget.from(snapshot: snapshot))
        let payload = try XCTUnwrap(target.wirePayload(for: attachment()))
        let frame = try XCTUnwrap(payload["frame"] as? [String: Double])

        XCTAssertEqual(frame["x"], 0)
        XCTAssertEqual(frame["y"], 0)
        XCTAssertEqual(frame["width"], 100)
        XCTAssertEqual(frame["height"], 100)
    }

    func testUnknownCaptureKeepsTextAndOmitsFrame() throws {
        let snapshot = AXFocusSnapshot(
            selectedText: "text only",
            role: "AXStaticText",
            label: nil,
            frame: CGRect(x: 10, y: 10, width: 20, height: 20),
            isEditable: false,
            isSecureField: false,
            isElementSelected: false,
            status: .complete,
            collectionPasses: 1
        )
        let target = try XCTUnwrap(VisionFocusTarget.from(snapshot: snapshot))
        let unknown = ScreenshotAttachment(
            url: URL(fileURLWithPath: "/tmp/focus-target.png")
        )
        let payload = try XCTUnwrap(target.wirePayload(for: unknown))

        XCTAssertEqual(payload["text"] as? String, "text only")
        XCTAssertNil(payload["frame"])
        XCTAssertNil(target.normalizedFrame(in: unknown))
    }

    func testNormalizedFrameUsesClippedCaptureCoordinates() throws {
        let snapshot = AXFocusSnapshot(
            selectedText: "partly visible",
            role: "AXStaticText",
            label: nil,
            frame: CGRect(x: 50, y: 150, width: 100, height: 100),
            isEditable: false,
            isSecureField: false,
            isElementSelected: false,
            status: .complete,
            collectionPasses: 1
        )
        let target = try XCTUnwrap(VisionFocusTarget.from(snapshot: snapshot))
        let frame = try XCTUnwrap(target.normalizedFrame(in: attachment()))

        XCTAssertEqual(frame.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(frame.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(frame.width, 0.125, accuracy: 0.0001)
        XCTAssertEqual(frame.height, 1.0 / 6.0, accuracy: 0.0001)
    }

    func testPresentationUsesNeutralRoleAndSourceNames() throws {
        let snapshot = AXFocusSnapshot(
            selectedText: nil,
            role: "AXButton",
            label: "送信",
            frame: CGRect(x: 120, y: 220, width: 80, height: 30),
            isEditable: false,
            isSecureField: false,
            isElementSelected: true,
            status: .complete,
            collectionPasses: 1
        )
        let target = try XCTUnwrap(VisionFocusTarget.from(snapshot: snapshot))

        XCTAssertEqual(target.displayTitle, "選択中のボタン")
        XCTAssertEqual(target.sourceDescription, "画面要素")
    }

    func testTextIsBoundedAndControlCharactersAreRemoved() throws {
        let source = "A\u{0000}B" + String(repeating: "x", count: 12_100)
        let snapshot = AXFocusSnapshot(
            selectedText: source,
            role: "AXStaticText",
            label: nil,
            frame: nil,
            isEditable: false,
            isSecureField: false,
            isElementSelected: false,
            status: .complete,
            collectionPasses: 1
        )
        let target = try XCTUnwrap(VisionFocusTarget.from(snapshot: snapshot))
        let payload = try XCTUnwrap(target.wirePayload(for: attachment()))
        let text = try XCTUnwrap(payload["text"] as? String)

        XCTAssertEqual(text.count, 12_000)
        XCTAssertFalse(text.contains("\u{0000}"))
        XCTAssertEqual(payload["truncated"] as? Bool, true)
    }

    func testEmojiTextUsesGatewayUTF16Limit() throws {
        let snapshot = AXFocusSnapshot(
            selectedText: String(repeating: "😀", count: 7_000),
            role: "AXStaticText",
            label: nil,
            frame: nil,
            isEditable: false,
            isSecureField: false,
            isElementSelected: false,
            status: .complete,
            collectionPasses: 1
        )
        let target = try XCTUnwrap(VisionFocusTarget.from(snapshot: snapshot))
        let payload = try XCTUnwrap(target.wirePayload(for: attachment()))
        let text = try XCTUnwrap(payload["text"] as? String)

        XCTAssertEqual(text.utf16.count, 12_000)
        XCTAssertEqual(payload["truncated"] as? Bool, true)
    }

    func testElementTargetRequiresMeaningfulSelectedElement() {
        let snapshot = AXFocusSnapshot(
            selectedText: nil,
            role: "AXWebArea",
            label: nil,
            frame: nil,
            isEditable: false,
            isSecureField: false,
            isElementSelected: true,
            status: .complete,
            collectionPasses: 1
        )

        XCTAssertNil(VisionFocusTarget.from(snapshot: snapshot))
    }

    private func attachment() -> ScreenshotAttachment {
        ScreenshotAttachment(
            url: URL(fileURLWithPath: "/tmp/focus-target.png"),
            pixelWidth: 800,
            pixelHeight: 600,
            captureScope: .display,
            captureRect: CGRect(x: 100, y: 200, width: 400, height: 300)
        )
    }
}
