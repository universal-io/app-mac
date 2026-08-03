import XCTest
@testable import Universal_IO

/// Starting a vision session must not depend on a view existing, being laid
/// out, or receiving an appearance callback. On 2026-08-03 it did: the first
/// request was fired from SwiftUI's `.task`, and a summon whose callback never
/// arrived produced no request, no spinner, and no error at all.
///
/// These tests run with no view in the process. If the session cannot reach an
/// outcome here, it cannot be relied on to reach one on screen either.
@MainActor
final class VisionSessionStartTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Diagnostics.resetForTesting()
    }

    override func tearDown() {
        Diagnostics.resetForTesting()
        super.tearDown()
    }

    func testStartReachesAnOutcomeWithoutAnyView() {
        let session = makeSession()

        session.startIfNeeded()

        // The unconfigured gateway is the fastest terminal state available in a
        // test process, and reaching it is the property under test: the session
        // ran, decided, and said so. Silence is the failure mode being fixed.
        XCTAssertNotNil(session.errorMessage)
        XCTAssertTrue(Diagnostics.recent(10).contains { $0.event == "vision.start" })
    }

    /// The coordinator owns the start (`handleVisionCaptureCompletion`). The
    /// guard must hold anyway, so that re-entering by any future path — a
    /// retry, a watchdog, a restored panel — cannot bill a second request.
    func testStartIsIdempotent() {
        let session = makeSession()

        session.startIfNeeded()
        session.startIfNeeded()
        session.startIfNeeded()

        let starts = Diagnostics.recent(50).filter { $0.event == "vision.start" }
        XCTAssertEqual(starts.count, 1)
    }

    private func makeSession() -> VisionSession {
        VisionSession(
            attachment: ScreenshotAttachment(
                url: URL(fileURLWithPath: "/tmp/vision-start-test.png"),
                pixelWidth: 800,
                pixelHeight: 600,
                captureScope: .display,
                captureRect: CGRect(x: 0, y: 0, width: 800, height: 600)
            ),
            client: nil
        )
    }
}
