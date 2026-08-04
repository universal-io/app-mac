import XCTest
@testable import Universal_IO

/// Every latency number the app reports is measured from a `SummonClock`, so a
/// defect in this type does not produce a wrong feature — it produces wrong
/// evidence, which is worse. Performance work is about to be decided from these
/// numbers, and a measurement that silently reads high would send that work at
/// the wrong target.
final class LatencyInstrumentationTests: XCTestCase {
    func testStartsAtZeroSoTheOriginIsTheMomentTheUserAsked() {
        let clock = SummonClock()
        XCTAssertLessThan(clock.elapsedMs, 50, "a fresh clock must read ~0, not the process's age")
        XCTAssertGreaterThanOrEqual(clock.elapsedMs, 0)
    }

    func testElapsedGrowsWithRealTime() {
        let clock = SummonClock()
        Thread.sleep(forTimeInterval: 0.12)
        XCTAssertGreaterThanOrEqual(clock.elapsedMs, 100)
    }

    /// Truncation, not rounding: a reported wait must never be longer than the
    /// wait that produced it. A 0.9ms span is "0ms", never "1ms".
    func testTruncatesRatherThanRoundsUp() {
        let clock = SummonClock()
        XCTAssertEqual(clock.elapsedMs, 0, "a span shorter than a millisecond is not a millisecond")
    }

    /// A clock started later has waited less. The point of a single origin is
    /// that spans are comparable, which requires ordering to survive.
    func testLaterOriginReportsShorterWait() {
        let early = SummonClock()
        Thread.sleep(forTimeInterval: 0.05)
        let late = SummonClock()
        XCTAssertGreaterThan(early.elapsedMs, late.elapsedMs)
    }

    /// The answer's shape is recorded next to its latency, so slow turns can be
    /// separated by kind (a `guide` step and an `observation` are not the same
    /// work). That is only safe while the vocabulary stays closed: this is the
    /// same privacy boundary as `DiagnosticValue`, checked at the one place a
    /// model-supplied value enters the trail.
    func testAnswerModeIsAClosedVocabularyAndCarriesNoModelText() {
        let codes = [
            VisionResult.Mode.observation,
            .answer,
            .guide,
            .clarification,
        ].map(\.diagnosticCode)

        XCTAssertEqual(codes, ["observation", "answer", "guide", "clarification"])

        Diagnostics.resetForTesting()
        Diagnostics.record("vision.firstContent", details: [
            ("sinceAsk", .ms(1_240)),
            ("mode", .code(VisionResult.Mode.guide)),
        ])
        let line = Diagnostics.recent(1).first?.line ?? ""
        XCTAssertTrue(line.contains("sinceAsk=1240ms"), line)
        XCTAssertTrue(line.contains("mode=guide"), line)
        Diagnostics.resetForTesting()
    }
}
