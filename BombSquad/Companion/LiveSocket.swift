import Foundation

enum LiveSocketError: UserPresentableError {
    case badURL
    case setupTimedOut
    case setupRejected
    /// The server closed the socket before accepting the setup — an expired
    /// or reused token looks like this.
    case closed(code: Int)

    var errorDescription: String? {
        switch self {
        case .badURL, .setupRejected, .closed:
            return "声の相棒に接続できませんでした。"
        case .setupTimedOut:
            return "声の相棒の応答がありませんでした。ネットワークを確認してください。"
        }
    }
}

/// One WebSocket to the Gemini Live API. Knows frames, not the conversation.
///
/// Sends are safe from any thread: audio arrives on the render thread and
/// video on the capture queue. A `URLSession` per socket, so closing one
/// connection during a reconnect cannot touch the next.
final class LiveSocket: @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: url)
        // Server audio arrives in small pieces, but a tool result or a usage
        // report can be larger than the 1 MB default.
        task.maximumMessageSize = 16 * 1024 * 1024
    }

    /// Opens the socket, sends the setup, and returns once the server has
    /// accepted it. Nothing else may be sent before `setupComplete`.
    func open(setup: [String: Any], timeout: TimeInterval) async throws {
        task.resume()
        guard let text = LiveWire.encode(LiveWire.setup(setup)) else { throw LiveSocketError.setupRejected }
        try await task.send(.string(text))
        // `receive()` does not answer to task cancellation; cancelling the
        // socket is what ends a wait that took too long.
        let timedOut = OnceFlag()
        let watchdog = Task { [task] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            timedOut.set()
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        let first: URLSessionWebSocketTask.Message
        do {
            first = try await task.receive()
        } catch {
            if timedOut.isSet { throw LiveSocketError.setupTimedOut }
            if task.closeCode != .invalid { throw LiveSocketError.closed(code: task.closeCode.rawValue) }
            throw error
        }
        guard Self.events(in: first).contains(.setupComplete) else {
            throw LiveSocketError.setupRejected
        }
    }

    /// Server messages until the socket closes. Ends normally on a close and
    /// throws only for transport failures; either way the caller reconnects or
    /// stops, so the difference is recorded, not branched on.
    func events() -> AsyncThrowingStream<[LiveEvent], Error> {
        AsyncThrowingStream { continuation in
            let reader = Task { [task] in
                while !Task.isCancelled {
                    do {
                        let message = try await task.receive()
                        let events = Self.events(in: message)
                        if !events.isEmpty { continuation.yield(events) }
                    } catch {
                        if task.closeCode != .invalid {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: error)
                        }
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    func send(_ message: [String: Any]) {
        guard let text = LiveWire.encode(message) else { return }
        // Fire and forget: a failed send means the socket is closing, and the
        // reader is the one that notices and reconnects.
        task.send(.string(text)) { _ in }
    }

    var closeCode: Int { task.closeCode.rawValue }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    private static func events(in message: URLSessionWebSocketTask.Message) -> [LiveEvent] {
        switch message {
        case .data(let data):
            return LiveEvent.parse(data)
        case .string(let text):
            return LiveEvent.parse(Data(text.utf8))
        @unknown default:
            return []
        }
    }
}

/// A flag one task raises and another reads after the fact.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func set() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}

/// The socket that is current right now, reachable from the audio thread and
/// the capture queue. Sends while none is open are dropped: sound from before
/// the connection is not part of the conversation, and a reconnect lasts a
/// few hundred milliseconds.
final class LiveUplink: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: LiveSocket?

    func replace(_ socket: LiveSocket?) {
        lock.lock()
        self.socket = socket
        lock.unlock()
    }

    func send(_ message: [String: Any]) {
        lock.lock()
        let socket = self.socket
        lock.unlock()
        socket?.send(message)
    }
}
