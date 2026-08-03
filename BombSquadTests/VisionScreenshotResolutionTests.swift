import AppKit
import XCTest
@testable import Universal_IO

/// The screenshot the user sees must not depend on a view appearing. It used to
/// be read in `ZoomableScreenshotView.onAppear`, so the 2026-08-03 panel opened
/// with an empty frame — no image, and nothing saying why.
///
/// Nothing in this file constructs a view.
@MainActor
final class VisionScreenshotResolutionTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles = []
        Diagnostics.resetForTesting()
        super.tearDown()
    }

    func testImageResolvesFromSessionLifecycleAlone() async throws {
        let url = try writePNG()
        let session = VisionSession(attachment: attachment(url: url), client: nil)

        let state = try await waitForResolution(of: session)

        guard case .ready(let image) = state else {
            return XCTFail("expected a resolved image, got \(state)")
        }
        XCTAssertGreaterThan(image.size.width, 0)
    }

    /// An unreadable capture is a state the panel can explain. Silence is not:
    /// the empty frame told the user nothing, which is why `.failed` exists as
    /// its own case rather than as a `nil` image.
    func testUnreadableCaptureResolvesToFailedRatherThanStayingBlank() async throws {
        let missing = URL(fileURLWithPath: "/tmp/universal-io-tests/does-not-exist.png")
        let session = VisionSession(attachment: attachment(url: missing), client: nil)

        let state = try await waitForResolution(of: session)

        guard case .failed = state else {
            return XCTFail("expected .failed, got \(state)")
        }
        XCTAssertTrue(
            Diagnostics.recent(20).contains { $0.event == "vision.screenshotUnreadable" }
        )
    }

    // MARK: - Helpers

    private func waitForResolution(
        of session: VisionSession,
        timeout: TimeInterval = 3
    ) async throws -> ScreenshotImageState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .loading = session.screenshotImage {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            return session.screenshotImage
        }
        return session.screenshotImage
    }

    private func attachment(url: URL) -> ScreenshotAttachment {
        ScreenshotAttachment(
            url: url,
            pixelWidth: 40,
            pixelHeight: 30,
            captureScope: .display,
            captureRect: CGRect(x: 0, y: 0, width: 40, height: 30)
        )
    }

    /// A real PNG on disk. A fabricated path would test the failure branch by
    /// accident and prove nothing about the success one.
    private func writePNG() throws -> URL {
        let image = NSImage(size: NSSize(width: 40, height: 30))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 30).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            throw XCTSkip("could not encode a test PNG on this machine")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("universal-io-screenshot-\(UUID().uuidString).png")
        try png.write(to: url)
        temporaryFiles.append(url)
        return url
    }
}
