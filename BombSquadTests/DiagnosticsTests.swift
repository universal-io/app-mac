import XCTest
@testable import Universal_IO

/// The diagnostics trail exists to answer one question after a silent stall:
/// did the request ever leave? It is also handed to us by the user, so what it
/// may contain is a privacy boundary, not a formatting preference.
final class DiagnosticsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Diagnostics.resetForTesting()
    }

    override func tearDown() {
        Diagnostics.resetForTesting()
        super.tearDown()
    }

    func testRecordsEventWithModeAndDetails() {
        Diagnostics.record("vision.request", mode: .vision, details: [
            ("turn", .code(VisionTurnKind.first)),
            ("identity", .ms(120)),
            ("candidates", .count(0)),
        ])

        let line = Diagnostics.recent(1).first?.line
        XCTAssertEqual(Diagnostics.recordedCount, 1)
        XCTAssertTrue(line?.contains("vision.request") == true)
        XCTAssertTrue(line?.contains("mode=vision") == true)
        XCTAssertTrue(line?.contains("turn=first") == true)
        XCTAssertTrue(line?.contains("identity=120ms") == true)
        XCTAssertTrue(line?.contains("candidates=0") == true)
    }

    /// The distinction the 2026-08-03 log could not make. `vision.start`
    /// without `vision.request` means the session never asked; `vision.request`
    /// without `vision.turn` or `vision.failed` means it asked and was never
    /// answered. Both must be separable from the trail alone.
    func testStartAndRequestAreSeparateEvents() {
        Diagnostics.record("vision.start")
        let startedOnly = Diagnostics.recent(10).map(\.event)
        XCTAssertEqual(startedOnly, ["vision.start"])

        Diagnostics.record("vision.request")
        XCTAssertEqual(Diagnostics.recent(10).map(\.event), ["vision.start", "vision.request"])
    }

    func testRingBufferKeepsNewestAndBoundsMemory() {
        for _ in 0..<(Diagnostics.capacity + 25) {
            Diagnostics.record("state.transition", mode: .idle)
        }
        XCTAssertEqual(Diagnostics.recordedCount, Diagnostics.capacity)
    }

    func testExportCarriesUptimeBecauseTheFailureOnlyAppearsAfterALongOne() {
        let launch = Date(timeIntervalSince1970: 0)
        Diagnostics.resetForTesting(launchedAt: launch)
        Diagnostics.record("coordinator.started", mode: .idle)

        let text = Diagnostics.exportText(now: launch.addingTimeInterval(38 * 3600 + 12 * 60))
        XCTAssertTrue(text.contains("uptime=38h12m"), text)
        XCTAssertTrue(text.contains("coordinator.started"), text)
    }

    /// The privacy boundary of README「データ保存」, pinned. Every value a caller
    /// can construct is a number, a flag, a compile-time literal, or a code
    /// from a closed vocabulary — there is no case that accepts free text, so a
    /// draft, an answer, a window title, or a host name cannot be recorded.
    func testExportedTrailContainsNoFreeText() {
        Diagnostics.record("coordinator.event", mode: .compose, details: [
            ("event", .code(AppEvent.doubleTap)),
        ])
        Diagnostics.record("state.transition", mode: .vision, details: [
            ("from", .code(AppMode.capturing(returnTo: .idle))),
            ("reason", .code(TransitionReason.captureCompleted)),
        ])
        Diagnostics.record("vision.failed", details: [
            ("error", .code(DiagnosticErrorClass(
                ProviderError.http(status: 502, body: "upstream said: 山田さんの下書き")
            ))),
        ])

        let text = Diagnostics.exportText()
        XCTAssertFalse(text.contains("山田"))
        XCTAssertFalse(text.contains("upstream said"))
        XCTAssertTrue(text.contains("error=provider.http.502"))
    }

    /// Gateway errors arrive with server-written text in the payload. The class
    /// is worth recording; the message is exactly what must not be.
    func testGatewayMessageIsReducedToItsClass() {
        let code = DiagnosticErrorClass(
            ProviderError.gateway(message: "画面の読み取りに失敗しました（mail.google.com）")
        ).diagnosticCode
        XCTAssertEqual(code, "provider.gateway")
    }

    /// The AX collector carries its stop reason as a `String?` because the wire
    /// payload needs it that way. Recording it therefore needs a gate: known
    /// reasons pass, anything else collapses. Without this, a later change that
    /// put a window title or a host name in that field would quietly start
    /// writing it to a trail the user hands over.
    func testUnknownTruncationReasonsCollapseInsteadOfPassingThrough() {
        XCTAssertEqual(AXTruncationCode("node_limit").diagnosticCode, "node_limit")
        XCTAssertEqual(AXTruncationCode("deadline").diagnosticCode, "deadline")
        XCTAssertEqual(AXTruncationCode(nil).diagnosticCode, "complete")
        XCTAssertEqual(
            AXTruncationCode("mail.google.com - 山田さん").diagnosticCode,
            "other"
        )
    }

    func testCancellationIsRecognizedAsItsOwnClass() {
        XCTAssertEqual(DiagnosticErrorClass(CancellationError()).diagnosticCode, "cancelled")
    }

    func testURLErrorsKeepTheirCodeSoOfflineIsDistinguishable() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(DiagnosticErrorClass(offline).diagnosticCode, "url.-1009")
    }
}
