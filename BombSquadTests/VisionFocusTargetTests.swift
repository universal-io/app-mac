import XCTest
@testable import Universal_IO

final class VisionSelectionContextTests: XCTestCase {
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
        XCTAssertEqual(selection.structures.count, 2)
        XCTAssertEqual(selection.structures.first?.relationship, .intersectsSelection)
        XCTAssertEqual(selection.structures.first?.coverage, .partial)
        XCTAssertEqual(selection.structures.last?.relationship, .selectionContainer)
        XCTAssertEqual(selection.structures.last?.coverage, .whole)
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
            allowVisualFallback: true
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

    func testSelectionWirePayloadKeepsBothEndsWithinUTF16Limit() throws {
        let text = "HEAD-" + String(repeating: "😀", count: 7_000) + "-TAIL"
        let selection = VisionSelectionContext(
            kind: .text,
            text: text,
            structures: [],
            frames: [],
            acquisitionCompleteness: .complete,
            acquisition: .axDocumentSelection,
            captureVisibility: .unknown
        )

        let payload = try XCTUnwrap(selection.wirePayload(for: attachment()))
        let wireText = try XCTUnwrap(payload["text"] as? String)

        XCTAssertLessThanOrEqual(wireText.utf16.count, 12_000)
        XCTAssertTrue(wireText.hasPrefix("HEAD-"))
        XCTAssertTrue(wireText.hasSuffix("-TAIL"))
        XCTAssertTrue(wireText.contains("UTF-16 units"))
        XCTAssertEqual(payload["wire_truncated"] as? Bool, true)
        XCTAssertEqual(payload["original_utf16_units"] as? Int, text.utf16.count)
        XCTAssertEqual(selection.text, text)
    }

    func testSelectionWirePayloadKeepsStructuresSeparateFromText() throws {
        let selection = VisionSelectionContext(
            kind: .text,
            text: "件名と本文の選択全文",
            structures: [
                VisionSelectionStructure(
                    source: .ax,
                    role: "AXHeading",
                    label: "短い件名",
                    parentLabel: "Gmail",
                    relationship: .intersectsSelection,
                    states: ["enabled"],
                    actions: [],
                    frame: CGRect(x: 150, y: 250, width: 100, height: 50),
                    coverage: .partial
                ),
            ],
            frames: [
                CGRect(x: 150, y: 250, width: 100, height: 50),
                CGRect(x: 300, y: 400, width: 50, height: 25),
            ],
            acquisitionCompleteness: .complete,
            acquisition: .axDocumentSelection,
            captureVisibility: .partial
        )

        let payload = try XCTUnwrap(selection.wirePayload(for: attachment()))
        let structures = try XCTUnwrap(payload["structures"] as? [[String: Any]])
        let frames = try XCTUnwrap(payload["frames"] as? [[String: Double]])

        XCTAssertEqual(payload["text"] as? String, "件名と本文の選択全文")
        XCTAssertEqual(structures.first?["label"] as? String, "短い件名")
        XCTAssertEqual(structures.first?["coverage"] as? String, "partial")
        XCTAssertEqual(frames.count, 2)
    }

    func testVisionRequestDiffersOnlyBySelectionExtension() throws {
        let attachment = attachment()
        let turns = [VisionTurn(role: .assistant, text: "直前の説明")]
        let candidates = [VisionObservation.Candidate(
            id: "candidate-1",
            source: "ax",
            role: "AXButton",
            label: "返信",
            rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
            parentLabel: "メール",
            states: ["enabled"]
        )]
        let diagnostics = VisionObservationCaptureService.Diagnostics(
            elapsedMs: 12,
            visitedNodes: 34,
            candidateCount: 1,
            truncatedReason: nil
        )
        let identity = VisionObservationCaptureService.TargetIdentity(
            appName: "Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "Gmail",
            host: "mail.google.com"
        )
        let selection = VisionSelectionContext(
            kind: .text,
            text: "件名と本文の選択全文",
            structures: [],
            frames: [],
            acquisitionCompleteness: .complete,
            acquisition: .axDocumentSelection,
            captureVisibility: .unknown
        )
        let ordinary = GatewayVisionClient.requestInput(
            attachment: attachment,
            imageBase64: "same-image",
            mediaType: "image/png",
            question: nil,
            turns: turns,
            candidates: candidates,
            candidateDiagnostics: diagnostics,
            identity: identity
        )
        var focusedWithoutExtension = GatewayVisionClient.requestInput(
            attachment: attachment,
            imageBase64: "same-image",
            mediaType: "image/png",
            question: nil,
            turns: turns,
            candidates: candidates,
            candidateDiagnostics: diagnostics,
            identity: identity,
            selection: selection
        )
        let selectionPayload = focusedWithoutExtension.removeValue(forKey: "selection")

        XCTAssertNotNil(selectionPayload)
        XCTAssertTrue(NSDictionary(dictionary: ordinary).isEqual(to: focusedWithoutExtension))
    }

    func testVisualOnlyWirePayloadHasNoSyntheticText() throws {
        let payload = try XCTUnwrap(
            VisionSelectionContext.visualOnly().wirePayload(for: attachment())
        )

        XCTAssertEqual(payload["kind"] as? String, "visual_only")
        XCTAssertEqual(payload["acquisition_completeness"] as? String, "visual_only")
        XCTAssertEqual(payload["original_utf16_units"] as? Int, 0)
        XCTAssertNil(payload["text"])
    }

    func testAccessibilityElementSelectionKeepsStructureWithoutSyntheticText() throws {
        let selection = try XCTUnwrap(VisionSelectionContext.accessibilityElement(
            role: "AXButton",
            label: "送信",
            frame: CGRect(x: 150, y: 250, width: 100, height: 50)
        ))

        XCTAssertEqual(selection.kind, .accessibilityElement)
        XCTAssertNil(selection.text)
        XCTAssertEqual(selection.acquisition, .axElement)
        XCTAssertEqual(selection.structures.first?.role, "AXButton")
        XCTAssertEqual(selection.structures.first?.label, "送信")
    }

    func testSelectionResolvesCaptureVisibilityFromAllFrames() {
        let base = VisionSelectionContext(
            kind: .text,
            text: "選択本文",
            structures: [],
            frames: [
                CGRect(x: 150, y: 250, width: 100, height: 50),
                CGRect(x: 450, y: 450, width: 100, height: 100),
            ],
            acquisitionCompleteness: .complete,
            acquisition: .axSelectedText,
            captureVisibility: .unknown
        )

        XCTAssertEqual(
            base.resolvingCaptureVisibility(for: attachment()).captureVisibility,
            .partial
        )

        let offCapture = VisionSelectionContext(
            kind: .text,
            text: "画面外",
            structures: [],
            frames: [CGRect(x: 700, y: 700, width: 20, height: 20)],
            acquisitionCompleteness: .complete,
            acquisition: .axSelectedText,
            captureVisibility: .unknown
        )
        XCTAssertEqual(
            offCapture.resolvingCaptureVisibility(for: attachment()).captureVisibility,
            .offCapture
        )
    }

    func testTextSelectionPresentationShowsFullTextAndEveryVisibleFrame() {
        let selection = VisionSelectionContext(
            kind: .text,
            text: "件名と、ユーザーが明示的に選択した本文全体",
            structures: [
                VisionSelectionStructure(
                    source: .ax,
                    role: "AXHeading",
                    label: "短い件名",
                    parentLabel: "Gmail",
                    relationship: .intersectsSelection,
                    states: [],
                    actions: [],
                    frame: nil,
                    coverage: .partial
                ),
            ],
            frames: [
                CGRect(x: 150, y: 250, width: 100, height: 50),
                CGRect(x: 50, y: 150, width: 100, height: 100),
                CGRect(x: 700, y: 700, width: 20, height: 20),
            ],
            acquisitionCompleteness: .complete,
            acquisition: .axDocumentSelection,
            captureVisibility: .partial
        )

        let presentation = VisionSelectionPresentation(
            selection: selection,
            attachment: attachment()
        )

        XCTAssertEqual(presentation.title, "選択した内容")
        XCTAssertEqual(presentation.bodyText, selection.text)
        XCTAssertNotEqual(presentation.bodyText, "短い件名")
        XCTAssertEqual(presentation.visibleFrames.count, 2)
        XCTAssertEqual(presentation.positionText, "2か所の選択位置を表示中")
        XCTAssertNil(presentation.statusText)
    }

    func testVisualOnlyPresentationAnnouncesImageInspection() {
        let presentation = VisionSelectionPresentation(
            selection: .visualOnly(captureVisibility: .visible),
            attachment: attachment()
        )

        XCTAssertEqual(presentation.title, "選択範囲")
        XCTAssertEqual(presentation.statusText, "選択範囲を画像から確認中")
        XCTAssertNil(presentation.bodyText)
        XCTAssertNil(presentation.positionText)
    }

    func testElementPresentationMayUseItsOwnLabel() throws {
        let selection = try XCTUnwrap(VisionSelectionContext.accessibilityElement(
            role: "AXButton",
            label: "送信",
            frame: CGRect(x: 150, y: 250, width: 100, height: 50)
        ))
        let presentation = VisionSelectionPresentation(
            selection: selection,
            attachment: attachment()
        )

        XCTAssertEqual(presentation.title, "選択した画面要素")
        XCTAssertEqual(presentation.bodyText, "送信")
        XCTAssertEqual(presentation.positionText, "1か所の選択位置を表示中")
    }

    func testOffCapturePresentationDoesNotClaimAVisiblePosition() {
        let selection = VisionSelectionContext(
            kind: .text,
            text: "画面外の選択",
            structures: [],
            frames: [CGRect(x: 700, y: 700, width: 20, height: 20)],
            acquisitionCompleteness: .complete,
            acquisition: .axSelectedText,
            captureVisibility: .offCapture
        )
        let presentation = VisionSelectionPresentation(
            selection: selection,
            attachment: attachment()
        )

        XCTAssertTrue(presentation.visibleFrames.isEmpty)
        XCTAssertEqual(
            presentation.positionText,
            "選択位置はこのスクリーンショットの範囲外です"
        )
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
