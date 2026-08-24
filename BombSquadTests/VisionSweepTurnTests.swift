import XCTest
@testable import Universal_IO

/// One statement of scope at a time.
///
/// Selection outranks pointer geometry in the Gateway's prompt, so a stale one
/// is not clutter — it hijacks every later turn: a session opened on selected
/// text whose user then taps a button would keep answering about the text.
/// Nothing throws when both are set, which is why the exclusivity is pinned
/// here.
@MainActor
final class VisionSweepTurnTests: XCTestCase {
    func testASweepTurnCarriesTheTextAndNoPointer() {
        let session = makeSession()
        session.point(
            pointer: VisionPointer(kind: .point(CGPoint(x: 0.5, y: 0.5))),
            capture: attachment(),
            candidates: [],
            diagnostics: nil,
            hit: nil
        )

        session.select(
            selection: sweptText("選んだ文"),
            capture: attachment(),
            candidates: [],
            diagnostics: nil
        )

        XCTAssertNil(session.pointer, "a sweep's scope is its text; pointer geometry must not survive it")
        XCTAssertEqual(session.selection?.text, "選んだ文")
        XCTAssertEqual(session.selection?.acquisition, .axRangeAtPointer)
        XCTAssertEqual(
            session.turns.map(\.text), [VisionSession.sweptTextHereText],
            "a new subject drops the conversation, same as pointing"
        )
    }

    func testAPointingTurnRetiresTheSweptText() {
        let session = makeSession()
        session.select(
            selection: sweptText("前の選択"),
            capture: attachment(),
            candidates: [],
            diagnostics: nil
        )

        session.beginPointing()

        XCTAssertNil(session.selection, "the launch or sweep selection must not scope the next tap")
        XCTAssertNil(session.pointer)
    }

    private func sweptText(_ text: String) -> VisionSelectionContext {
        VisionSelectionContext(
            kind: .text,
            text: text,
            structures: [],
            frames: [],
            acquisitionCompleteness: .complete,
            acquisition: .axRangeAtPointer,
            captureVisibility: .unknown
        )
    }

    private func attachment() -> ScreenshotAttachment {
        ScreenshotAttachment(
            url: URL(fileURLWithPath: "/tmp/vision-sweep-test.png"),
            pixelWidth: 800,
            pixelHeight: 600,
            captureScope: .display,
            captureRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }

    private func makeSession() -> VisionSession {
        VisionSession(attachment: attachment(), client: nil)
    }
}
