import Foundation

/// Every wait in this app that a user is sitting in front of.
///
/// Before R11 there were none: no `timeoutInterval`, no `maxDuration`, and an
/// unbounded `await` on the Supabase session. "Stopped" and "slow" therefore
/// looked identical from the outside, and the only advice available to a user
/// was to restart the app.
///
/// The numbers are budgets, not guesses at typical latency. A vision round trip
/// measured 2.4s–8.0s in ordinary use, and the gateway may run a second model
/// after the first fails, so the client budget must clear the gateway's own
/// ceiling rather than race it.
enum OperationDeadline {
    /// Reading the signed-in session. Local or a Supabase refresh; either way
    /// this is the one wait that used to leave no trace at all when it hung —
    /// it happens before the network request exists, so not even a CFNetwork
    /// entry appeared in the log.
    static let accessToken: TimeInterval = 10

    /// A single gateway request, from send to response.
    static let visionRequest: TimeInterval = 90
    static let reviewRequest: TimeInterval = 90
    static let transcribeRequest: TimeInterval = 60
    static let suggestRequest: TimeInterval = 60
    /// Account, billing, and quota reads. Short: nothing the user is composing
    /// depends on them.
    static let accountRequest: TimeInterval = 20

    /// One whole vision turn, including the AX candidate walk and the product
    /// identity resolution, neither of which is a network wait and neither of
    /// which the request timeout above can bound.
    static let visionTurn: TimeInterval = 120

    /// How long the coordinator waits for a vision session to have issued its
    /// request before assuming it never will. Generous compared with the
    /// milliseconds the start actually takes, because a false retry costs a
    /// duplicate request while a missed one costs the whole session.
    static let visionStartWatchdog: TimeInterval = 8
}

/// Raised when a budget above is exceeded. Distinct from a transport timeout so
/// the trail can say which ceiling was hit.
struct OperationTimeoutError: LocalizedError {
    let operation: String

    var errorDescription: String? {
        "処理が時間内に完了しませんでした。"
    }
}

/// Runs `work` with a hard ceiling.
///
/// Whichever finishes first wins and the other side is cancelled, so this
/// cannot leak a task. Used for waits that are not a single URL request —
/// those are bounded by `URLRequest.timeoutInterval` at the transport itself.
func withDeadline<Success: Sendable>(
    seconds: TimeInterval,
    operation: String,
    work: @escaping @Sendable () async throws -> Success
) async throws -> Success {
    try await withThrowingTaskGroup(of: Success.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw OperationTimeoutError(operation: operation)
        }
        guard let first = try await group.next() else {
            throw OperationTimeoutError(operation: operation)
        }
        group.cancelAll()
        return first
    }
}
