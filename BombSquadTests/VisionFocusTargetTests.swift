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

    func testSelectionResolverChoosesDocumentTextOverShortInnerFragment() throws {
        let candidates = [
            selectionCandidate(
                text: "件名",
                role: "AXHeading",
                label: "件名",
                scope: .focusedElement,
                depth: 0
            ),
            selectionCandidate(
                text: "件名と、ユーザーが明示的に選択した本文全体",
                role: "AXWebArea",
                label: "Gmail",
                scope: .document,
                depth: 10,
                rangeEvidence: .mismatching
            ),
        ]

        let selection = try XCTUnwrap(VisionSelectionResolver.resolve(candidates: candidates))

        XCTAssertEqual(selection.text, "件名と、ユーザーが明示的に選択した本文全体")
        XCTAssertEqual(selection.acquisition, .axDocumentSelection)
    }

    func testSelectionResolverNeverLetsShortLabelReplaceSelectedText() throws {
        let selectedText = "これはユーザーが選択した長い本文で、回答が必ず扱う対象です。"
        let first = selectionCandidate(
            text: selectedText,
            role: "AXGroup",
            label: "短い件名A",
            scope: .ancestor,
            depth: 2
        )
        let second = selectionCandidate(
            text: selectedText,
            role: "AXGroup",
            label: "短い件名B",
            scope: .ancestor,
            depth: 2
        )

        let firstResult = try XCTUnwrap(VisionSelectionResolver.resolve(candidates: [first]))
        let secondResult = try XCTUnwrap(VisionSelectionResolver.resolve(candidates: [second]))

        XCTAssertEqual(firstResult.text, selectedText)
        XCTAssertEqual(secondResult.text, selectedText)
        XCTAssertNotEqual(firstResult.structures, secondResult.structures)
    }

    func testSelectionResolverTreatsRangeMismatchAsSupportingEvidenceOnly() throws {
        let candidate = selectionCandidate(
            text: "公開AXSelectedTextが返した選択全文",
            role: "AXWebArea",
            label: "周辺ページ",
            scope: .document,
            depth: 8,
            rangeEvidence: .mismatching
        )

        let selection = try XCTUnwrap(VisionSelectionResolver.resolve(candidates: [candidate]))

        XCTAssertEqual(selection.text, candidate.directText)
        XCTAssertEqual(selection.kind, .text)
    }

    func testSelectionResolverUsesConsensusForNativeTextControl() throws {
        let candidates = [
            selectionCandidate(
                text: "選択本文",
                role: "AXTextArea",
                scope: .focusedElement,
                depth: 0,
                pass: 1
            ),
            selectionCandidate(
                text: "選択本文",
                role: "AXTextArea",
                scope: .focusedElement,
                depth: 0,
                pass: 2
            ),
            selectionCandidate(
                text: "別の不安定な断片",
                role: "AXGroup",
                scope: .ancestor,
                depth: 1,
                pass: 1
            ),
        ]

        let selection = try XCTUnwrap(VisionSelectionResolver.resolve(candidates: candidates))

        XCTAssertEqual(selection.text, "選択本文")
        XCTAssertEqual(selection.acquisition, .axSelectedText)
    }

    func testSelectionResolverDoesNotSubstituteStructureForMissingText() {
        let candidate = selectionCandidate(
            text: nil,
            role: "AXHeading",
            label: "件名",
            scope: .ancestor,
            depth: 2
        )

        XCTAssertNil(VisionSelectionResolver.resolve(candidates: [candidate]))
    }

    func testSelectionResolverFallsBackToVisualOnlyWithoutAXText() throws {
        let selection = try XCTUnwrap(VisionSelectionResolver.resolve(
            candidates: [],
            visualSelectionHint: true
        ))

        XCTAssertEqual(selection.kind, .visualOnly)
        XCTAssertNil(selection.text)
        XCTAssertEqual(selection.acquisitionCompleteness, .visualOnly)
    }

    func testSelectionResolverRejectsEntirePathWhenSecureCandidateAppears() {
        let ordinary = selectionCandidate(
            text: "must not survive",
            role: "AXTextArea",
            scope: .focusedElement,
            depth: 0
        )
        let secure = selectionCandidate(
            text: nil,
            role: "AXTextField",
            scope: .ancestor,
            depth: 1,
            isSecure: true
        )

        XCTAssertNil(VisionSelectionResolver.resolve(candidates: [ordinary, secure]))
    }

    func testSelectionResolverKeepsDistinctValidSelectionFrames() throws {
        let candidate = selectionCandidate(
            text: "複数位置",
            role: "AXWebArea",
            scope: .document,
            depth: 5,
            selectionFrames: [
                CGRect(x: 10, y: 20, width: 30, height: 40),
                CGRect(x: 10, y: 20, width: 30, height: 40),
                CGRect(x: 10, y: 80, width: 50, height: 20),
                .zero,
            ]
        )

        let selection = try XCTUnwrap(VisionSelectionResolver.resolve(candidates: [candidate]))

        XCTAssertEqual(selection.frames, [
            CGRect(x: 10, y: 20, width: 30, height: 40),
            CGRect(x: 10, y: 80, width: 50, height: 20),
        ])
    }

    private func selectionCandidate(
        text: String?,
        role: String?,
        label: String? = nil,
        scope: VisionSelectionCandidate.Scope,
        depth: Int,
        pass: Int = 1,
        rangeEvidence: VisionSelectionCandidate.RangeEvidence = .unavailable,
        selectionFrames: [CGRect] = [],
        isSecure: Bool = false
    ) -> VisionSelectionCandidate {
        VisionSelectionCandidate(
            directText: text,
            role: role,
            label: label,
            containerFrame: nil,
            selectionFrames: selectionFrames,
            scope: scope,
            depth: depth,
            pass: pass,
            rangeEvidence: rangeEvidence,
            isSecure: isSecure
        )
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
