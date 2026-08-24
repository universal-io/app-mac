import XCTest
@testable import Universal_IO

/// One statement of scope at a time.
///
/// Selection outranks pointer geometry in the Gateway's prompt, so a stale one
/// is not clutter — it hijacks every later turn: a session opened on selected
/// text whose user then taps a button would keep answering about the text.
/// Nothing throws when both are set, which is why the exclusivity is pinned
/// here. (Found while building the retired overlay text sweep; the bug it
/// fixes predates that feature and survives it.)
@MainActor
final class VisionSubjectExclusivityTests: XCTestCase {
    func testAPointingGestureRetiresTheLaunchSelection() {
        let session = VisionSession(
            attachment: attachment(),
            selection: VisionSelectionContext(
                kind: .text,
                text: "起動時に選択されていた文",
                structures: [],
                frames: [],
                acquisitionCompleteness: .complete,
                acquisition: .axSelectedText,
                captureVisibility: .unknown
            ),
            client: nil
        )

        session.beginPointing()

        XCTAssertNil(session.selection, "the launch selection must not scope the next tap")
        XCTAssertNil(session.pointer)
        XCTAssertTrue(session.turns.isEmpty, "a new subject drops the conversation")
    }

    private func attachment() -> ScreenshotAttachment {
        ScreenshotAttachment(
            url: URL(fileURLWithPath: "/tmp/vision-exclusivity-test.png"),
            pixelWidth: 800,
            pixelHeight: 600,
            captureScope: .display,
            captureRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }
}
