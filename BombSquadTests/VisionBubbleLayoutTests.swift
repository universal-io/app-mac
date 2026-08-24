import AppKit
import SwiftUI
import XCTest
@testable import Universal_IO

/// What the bubble actually measures, at the size the overlay asks for it.
///
/// `VisionBubbleHeightTests` pins the arithmetic that decides how much room the
/// answer may take. This pins the thing the user sees: the height the real view
/// reports to the real hosting view. The two came apart once — the budget was
/// raised from half the screen to what was left of it and the visible answer did
/// not change by a pixel — so the budget alone is not evidence.
@MainActor
final class VisionBubbleLayoutTests: XCTestCase {
    /// A long answer has to make the bubble tall. Anything that quietly caps the
    /// answer area — a scroll view chosen while the height proposal is
    /// unspecified, a stack that hands its child an ideal instead of a maximum —
    /// shows up here as a bubble that stays short no matter how much it is
    /// allowed.
    func testALongAnswerMakesTheBubbleTall() {
        let budget = VisionBubbleView.answerHeightBudget(visibleHeight: 1117)
        let short = measuredHeight(answer: "短い答え。", budget: budget)
        let long = measuredHeight(
            answer: String(repeating: "この画面について説明します。", count: 200),
            budget: budget
        )

        print("bubble short=\(short) long=\(long) budget=\(budget)")
        XCTAssertGreaterThan(
            long, short,
            "a long answer did not make the bubble any taller"
        )
        XCTAssertGreaterThanOrEqual(
            long, VisionBubbleView.answerHeight(within: budget),
            "the answer area did not use the room it was given"
        )
    }

    /// A short answer keeps the bubble small — but not a sliver.
    ///
    /// This is the pair of the test above, and the one that answers the actual
    /// complaint: raising the ceiling changed nothing visible because ordinary
    /// answers never reached it. The floor is what the reader sees.
    func testAShortAnswerStillGetsAReadingPane() {
        let budget = VisionBubbleView.answerHeightBudget(visibleHeight: 1117)
        let short = measuredHeight(answer: "短い答え。", budget: budget)
        print("bubble with a one-line answer=\(short)")
        XCTAssertGreaterThanOrEqual(
            short, VisionBubbleView.answerMinHeight(within: budget),
            "a one-line answer collapsed the reading pane"
        )
        XCTAssertLessThan(short, 400, "a one-line answer took over the screen")
    }

    /// The floor never rises above the ceiling. SwiftUI does not complain when a
    /// minimum exceeds a maximum, it just picks one, so a small display would
    /// silently get whichever the framework preferred that release.
    func testTheFloorNeverExceedsTheCeiling() {
        for visible in stride(from: 400.0, through: 2000.0, by: 13.0) {
            let budget = VisionBubbleView.answerHeightBudget(visibleHeight: CGFloat(visible))
            XCTAssertLessThanOrEqual(
                VisionBubbleView.answerMinHeight(within: budget),
                VisionBubbleView.answerHeight(within: budget),
                "floor above ceiling at \(visible)pt"
            )
        }
    }

    private func measuredHeight(answer: String, budget: CGFloat) -> CGFloat {
        let session = VisionSession(
            attachment: ScreenshotAttachment(
                url: URL(fileURLWithPath: "/tmp/vision-bubble-layout-test.png"),
                pixelWidth: 800,
                pixelHeight: 600,
                captureScope: .display,
                captureRect: CGRect(x: 0, y: 0, width: 800, height: 600)
            ),
            selection: nil,
            client: nil
        )
        // The error branch of `answer`, which is the same Text with the same
        // font and the same wrapping as a reply. The reply's own turns are not
        // writable from outside the session, and the layout does not care which
        // branch produced the string.
        session.errorMessage = answer

        let host = NSHostingView(
            rootView: AnyView(
                VisionBubbleView(
                    session: session,
                    answerHeightBudget: budget,
                    onClose: {}
                )
            )
        )
        host.sizingOptions = [.intrinsicContentSize]
        host.frame = NSRect(x: 0, y: 0, width: VisionPointingOverlay.bubbleWidth, height: 1)
        host.layoutSubtreeIfNeeded()
        return max(host.intrinsicContentSize.height, host.fittingSize.height)
    }
}
