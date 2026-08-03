import XCTest
@testable import Universal_IO

/// Two ways the app used to end an operation without saying anything, both
/// found while investigating the 2026-08-03 stall.
@MainActor
final class SilentFailureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Diagnostics.resetForTesting()
    }

    override func tearDown() {
        Diagnostics.resetForTesting()
        super.tearDown()
    }

    /// `close()` used to discard this result and tear the sessions down anyway.
    /// Since the mode had not actually changed, the panel stayed on screen with
    /// its requests cancelled and its capture deleted — a hollow panel. The
    /// caller can only be trusted to handle a refusal if a refusal really does
    /// leave the machine where it was.
    func testRefusedTransitionLeavesTheModeUnchanged() {
        let machine = AppStateMachine()

        XCTAssertFalse(machine.transition(to: .navigator, reason: .summon))

        XCTAssertEqual(machine.mode, .idle)
        XCTAssertTrue(
            Diagnostics.recent(10).contains { $0.event == "state.transition.refused" }
        )
    }

    func testRefusedTransitionDoesNotNotifyObservers() {
        let machine = AppStateMachine()
        var observed: [AppMode] = []
        machine.onTransition = { _, next, _ in observed.append(next) }

        XCTAssertFalse(machine.transition(to: .copilot, reason: .copilotStarted))

        // The panel is rebuilt from this callback. Firing it for a transition
        // that did not happen would present a panel for a mode the app is not in.
        XCTAssertTrue(observed.isEmpty)
    }

    func testAcceptedTransitionReportsSuccessAndMoves() {
        let machine = AppStateMachine()

        XCTAssertTrue(machine.transition(to: .compose, reason: .summon))

        XCTAssertEqual(machine.mode, .compose)
    }

    /// A cancelled request is only allowed to be silent when this session asked
    /// for the cancellation. Anything else threw away a request the user was
    /// waiting on, and that must reach the panel.
    func testCancellationLedgerStartsUnexplained() {
        let ledger = CancellationLedger()

        XCTAssertNil(ledger.cause)

        ledger.cause = .supersededByNewerRequest
        XCTAssertNotNil(ledger.cause)
    }
}
