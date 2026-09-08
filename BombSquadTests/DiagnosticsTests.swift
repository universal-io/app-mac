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

    /// The test above passes on a build whose uptime is permanently zero,
    /// because assigning the launch date is itself what initializes it. That is
    /// how a 32-hour process came to report `uptime=0h0m` with 68 tests green.
    ///
    /// This exercises the real path with no override. The invariant is
    /// ordering, not a duration: a process cannot have started after the first
    /// thing it recorded. When launch was resolved lazily at export time it was
    /// later than every entry, so this fails on the defect and needs no clock.
    func testLaunchDateIsNotResolvedWhenTheReportIsFirstRead() {
        Diagnostics.resetForTesting(launchedAt: nil)
        Diagnostics.record("coordinator.started", mode: .idle)
        let firstEntry = Diagnostics.recent(1).first
        XCTAssertNotNil(firstEntry)

        // Reading the report must not be what decides when the process began.
        _ = Diagnostics.exportText()
        let launched = Diagnostics.launchDate()

        XCTAssertLessThanOrEqual(
            launched,
            firstEntry!.at,
            "launch resolved after the first recorded event: uptime is being measured from first read"
        )
        XCTAssertGreaterThan(
            Date().timeIntervalSince(launched),
            0,
            "a running process must report a positive uptime"
        )
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

    /// Gateway errors arrive with server-written text in the payload. The
    /// contract's code is worth recording; the message beside it is exactly
    /// what must not be.
    func testGatewayMessageIsReducedToItsCode() {
        let code = DiagnosticErrorClass(
            ProviderError.gateway(
                message: "画面の読み取りに失敗しました（mail.google.com）",
                code: "QUOTA_EXCEEDED"
            )
        ).diagnosticCode
        XCTAssertEqual(code, "gateway.QUOTA_EXCEEDED")
    }

    /// The code arrives as a plain string in a JSON body. Recording it is only
    /// safe while unknown values cannot ride along, so an unrecognized code
    /// collapses and a missing contract body says so.
    func testUnknownGatewayCodesCollapseInsteadOfPassingThrough() {
        XCTAssertEqual(
            DiagnosticErrorClass(
                ProviderError.gateway(message: "…", code: "松本さんのトークン")
            ).diagnosticCode,
            "gateway.other"
        )
        XCTAssertEqual(
            DiagnosticErrorClass(
                ProviderError.gateway(message: "…", code: nil)
            ).diagnosticCode,
            "gateway.none"
        )
    }

    /// The failure this session started from: a refused request whose reason
    /// the user was never told. The reason is the gateway's own sentence, so it
    /// replaces the surface's "try again"; an internal fault has no such
    /// sentence and leaves the surface's wording alone.
    func testOnlySelfExplainingFailuresReplaceTheSurfaceWording() {
        XCTAssertEqual(
            UserFacingError.serverExplanation(
                for: ProviderError.gateway(
                    message: "今月の利用枠を使い切りました。",
                    code: "QUOTA_EXCEEDED"
                )
            ),
            "今月の利用枠を使い切りました。"
        )
        XCTAssertNil(
            UserFacingError.serverExplanation(for: ProviderError.decoding("bad json"))
        )
        XCTAssertNil(
            UserFacingError.serverExplanation(
                for: ProviderError.http(status: 502, body: "upstream said no")
            )
        )
        XCTAssertNotNil(
            UserFacingError.serverExplanation(
                for: ProviderError.transport(
                    code: URLError.Code.notConnectedToInternet.rawValue,
                    description: "offline"
                )
            )
        )
    }

    /// The AX collector carries its stop reason as a `String?` because the wire
    /// payload needs it that way. Recording it therefore needs a gate: known
    /// reasons pass, anything else collapses. Without this, a later change that
    /// put a window title or a host name in that field would quietly start
    /// writing it to a trail the user hands over.
    func testUnknownTruncationReasonsCollapseInsteadOfPassingThrough() {
        XCTAssertEqual(AXTruncationCode("node_limit").diagnosticCode, "node_limit")
        XCTAssertEqual(AXTruncationCode("deadline").diagnosticCode, "deadline")
        XCTAssertEqual(AXTruncationCode("window_off_capture").diagnosticCode, "window_off_capture")
        XCTAssertEqual(AXTruncationCode(nil).diagnosticCode, "complete")
        XCTAssertEqual(
            AXTruncationCode("mail.google.com - 山田さん").diagnosticCode,
            "other"
        )
    }

    func testPointCollectionOutcomeSeparatesEmptyCollectorFromOrdinaryMiss() {
        XCTAssertEqual(
            VisionPointCollectionOutcome.classify(candidateCount: 0, hit: false),
            .collectorEmpty
        )
        XCTAssertEqual(
            VisionPointCollectionOutcome.classify(candidateCount: 12, hit: false),
            .pointMiss
        )
        XCTAssertEqual(
            VisionPointCollectionOutcome.classify(candidateCount: 12, hit: true),
            .measured
        )
    }

    func testUnknownCollectionRootCannotEnterOperationalTrail() {
        XCTAssertEqual(AXCollectionRootCode("focused_window").diagnosticCode, "focused_window")
        XCTAssertEqual(
            AXCollectionRootCode("mail.google.com - 山田さん").diagnosticCode,
            "other"
        )
    }

    /// D7 exercised this for real: with Wi-Fi off, Vision failed explicitly in
    /// 51ms — correct — but recorded `provider.http.-1`, because the client
    /// flattened every transport failure into an HTTP error with a sentinel
    /// status. Offline, DNS failure, a dropped connection and a TLS failure all
    /// produced that one code, and the user was told "API エラー（-1）" while the
    /// problem was their own network.
    ///
    /// Support's first question is whether the user could reach us at all, so
    /// these must stay apart in the trail and must not blame the API in the UI.
    func testTransportFailuresStaySeparableFromServerErrors() {
        let offline = ProviderError.transport(
            code: URLError.notConnectedToInternet.rawValue,
            description: "The Internet connection appears to be offline."
        )
        let timedOut = ProviderError.transport(
            code: URLError.timedOut.rawValue,
            description: "The request timed out."
        )
        let serverFault = ProviderError.http(status: 502, body: "bad gateway")

        let codes = [offline, timedOut, serverFault].map { DiagnosticErrorClass($0).diagnosticCode }
        XCTAssertEqual(codes, ["transport.-1009", "transport.-1001", "provider.http.502"])
        XCTAssertEqual(Set(codes).count, 3, "a trail that cannot tell these apart cannot be triaged")

        let message = offline.errorDescription ?? ""
        XCTAssertFalse(message.contains("API"), message)
        XCTAssertTrue(message.contains("接続"), message)
    }

    /// A user reporting "the highlight stopped appearing" can be answered only
    /// if the three ways it can go missing are separable in the trail. They call
    /// for different fixes: the model naming no target is its judgement, an
    /// unresolvable one means the screen could not place what it named, and a
    /// resolved one means the ring was drawn and the fault lies downstream.
    func testHighlightOutcomeSeparatesTheThreeWaysARingGoesMissing() {
        let codes = [
            VisionHighlightOutcome.none,
            .resolved,
            .unresolvable,
        ].map(\.diagnosticCode)
        XCTAssertEqual(codes, ["none", "resolved", "unresolvable"])
        XCTAssertEqual(Set(codes).count, 3, "the cases must not collapse into each other")

        Diagnostics.record("vision.result", details: [
            ("mode", .code(VisionResult.Mode.guide)),
            ("highlight", .code(VisionHighlightOutcome.none)),
            ("candidates", .count(137)),
        ])
        let line = Diagnostics.recent(1).first?.line ?? ""
        XCTAssertTrue(line.contains("mode=guide"), line)
        XCTAssertTrue(line.contains("highlight=none"), line)
        XCTAssertTrue(line.contains("candidates=137"), line)
    }

    func testCancellationIsRecognizedAsItsOwnClass() {
        XCTAssertEqual(DiagnosticErrorClass(CancellationError()).diagnosticCode, "cancelled")
    }

    func testURLErrorsKeepTheirCodeSoOfflineIsDistinguishable() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(DiagnosticErrorClass(offline).diagnosticCode, "url.-1009")
    }
}
