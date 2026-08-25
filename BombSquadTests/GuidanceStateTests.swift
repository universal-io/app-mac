import XCTest
@testable import Universal_IO

/// Guidance as the second state of a Vision session (R15).
///
/// The rules here came out of the first field test: a guide answer to a typed
/// question is the moment the user reaches for the named control, so that is
/// when the wash has to go — and a pointing turn, whose user line is
/// "ここについて", must never become a goal.
@MainActor
final class GuidanceStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Diagnostics.resetForTesting()
    }

    override func tearDown() {
        Diagnostics.resetForTesting()
        super.tearDown()
    }

    /// Typed and guided: the only pair that opens guidance by itself.
    func testOnlyATypedQuestionAnsweredAsGuideOpensGuidance() {
        let turns: [VisionTurnKind] = [.first, .question, .pointing, .copilot]
        let modes: [VisionResult.Mode] = [.observation, .answer, .guide, .clarification]
        for turn in turns {
            for mode in modes {
                XCTAssertEqual(
                    VisionSession.opensGuidance(turn: turn, mode: mode),
                    turn == .question && mode == .guide,
                    "turn=\(turn) mode=\(mode)"
                )
            }
        }
    }

    /// Pointing and guiding are one session with a door between them, and the
    /// door opens both ways. The corner strip's intermediate mode is gone.
    func testTheModeTableHasATwoWayDoorBetweenPointingAndGuidance() {
        XCTAssertTrue(AppMode.vision.canTransition(to: .copilot))
        XCTAssertTrue(AppMode.copilot.canTransition(to: .vision))
        XCTAssertTrue(AppMode.copilot.canTransition(to: .idle))
        XCTAssertFalse(AppMode.idle.canTransition(to: .copilot), "guidance needs a session to guide")
        XCTAssertFalse(AppMode.compose.canTransition(to: .copilot))
    }

    /// The button asks for guidance; the cross gives it back. The conversation
    /// is kept across both, because the answer is still the answer — only the
    /// wash and what a click means have changed.
    func testTheCrossReturnsToPointingWithTheConversationIntact() {
        var requested: [(AppMode, TransitionReason)] = []
        let session = makeSession { target, reason in
            requested.append((target, reason))
            return true
        }
        session.input = "請求書を発行したい"
        session.sendQuestion()
        XCTAssertEqual(session.turns.count, 1, "the typed question is a turn even without a gateway")

        session.startCopilot()

        XCTAssertTrue(session.isCopilotActive)
        XCTAssertEqual(session.copilotGoal, "請求書を発行したい")
        XCTAssertEqual(requested.map(\.0), [.copilot])
        XCTAssertEqual(requested.map(\.1), [.copilotStarted])

        session.leaveGuidance()

        XCTAssertFalse(session.isCopilotActive)
        XCTAssertNil(session.copilotGoal)
        XCTAssertEqual(requested.map(\.0), [.copilot, .vision])
        XCTAssertEqual(requested.last?.1, .copilotLeft)
        XCTAssertEqual(session.turns.count, 1, "leaving guidance dropped the conversation")
        XCTAssertTrue(Diagnostics.recent(20).contains { $0.event == "guide.entered" })
        XCTAssertTrue(Diagnostics.recent(20).contains { $0.event == "guide.left" })
    }

    /// A refused transition leaves the session where it was: still pointing,
    /// with nothing believing the wash has gone.
    func testARefusedTransitionDoesNotLeaveTheSessionHalfGuiding() {
        let session = makeSession { _, _ in false }
        session.input = "請求書を発行したい"
        session.sendQuestion()

        session.startCopilot()

        XCTAssertFalse(session.isCopilotActive)
        XCTAssertNil(session.copilotGoal)
    }

    /// Nothing to guide toward: no user turn, no guidance.
    func testGuidanceNeedsAQuestionToBecomeTheGoal() {
        var requested = 0
        let session = makeSession { _, _ in requested += 1; return true }

        session.startCopilot()

        XCTAssertFalse(session.isCopilotActive)
        XCTAssertEqual(requested, 0)
    }

    /// The Gateway takes twenty turns. The newest survive.
    func testTheWireCarriesTheNewestTwentyTurns() {
        let turns = (0..<25).map { index in
            VisionDisplayTurn(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "turn \(index)",
                mode: nil,
                uncertainties: []
            )
        }
        let wire = VisionSession.wire(turns)
        XCTAssertEqual(wire.count, VisionSession.maxWireTurns)
        XCTAssertEqual(wire.first?.text, "turn 5")
        XCTAssertEqual(wire.last?.text, "turn 24")
    }

    private func makeSession(
        transition: @escaping (AppMode, TransitionReason) -> Bool
    ) -> VisionSession {
        VisionSession(
            attachment: ScreenshotAttachment(
                url: URL(fileURLWithPath: "/tmp/guidance-state-test.png"),
                pixelWidth: 800,
                pixelHeight: 600,
                captureScope: .display,
                captureRect: CGRect(x: 0, y: 0, width: 800, height: 600)
            ),
            client: nil,
            onRequestModeTransition: transition
        )
    }
}
