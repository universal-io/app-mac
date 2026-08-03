import XCTest
@testable import Universal_IO

/// "Stopped" and "slow" looked identical from outside the app because nothing
/// had a ceiling. These pin the primitive every user-visible wait now uses.
final class OperationDeadlineTests: XCTestCase {
    func testWorkThatFinishesInsideTheBudgetReturnsItsValue() async throws {
        let value = try await withDeadline(seconds: 5, operation: "test.fast") {
            "done"
        }
        XCTAssertEqual(value, "done")
    }

    func testWorkThatNeverFinishesRaisesATimeoutRatherThanHanging() async {
        do {
            _ = try await withDeadline(seconds: 0.05, operation: "test.hang") {
                try await Task.sleep(for: .seconds(30))
                return "unreachable"
            }
            XCTFail("expected the deadline to fire")
        } catch let error as OperationTimeoutError {
            XCTAssertEqual(error.operation, "test.hang")
        } catch {
            XCTFail("expected OperationTimeoutError, got \(error)")
        }
    }

    /// The deadline must not outlive the work it was guarding, or every bounded
    /// call would leak a sleeping task for the length of its budget.
    func testTheLosingSideIsCancelled() async throws {
        let started = Date()
        _ = try await withDeadline(seconds: 60, operation: "test.cleanup") { "done" }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// Each route's client budget must sit above the gateway's own ceiling for
    /// that route (two serial model calls under `maxDuration = 60`). A client
    /// that gives up first turns a server-side answer into a client-side error.
    func testClientBudgetsClearTheGatewayCeiling() {
        let gatewayCeiling: TimeInterval = 60
        XCTAssertGreaterThan(OperationDeadline.visionRequest, gatewayCeiling)
        XCTAssertGreaterThan(OperationDeadline.reviewRequest, gatewayCeiling)
        XCTAssertGreaterThan(OperationDeadline.visionTurn, OperationDeadline.visionRequest)
    }
}
