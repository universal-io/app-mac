import Foundation

/// One parsed SSE event from a gateway stream: the `event:` name and the
/// decoded JSON object of its single `data:` line.
struct GatewaySSEEvent {
    let name: String
    let json: [String: Any]
    let data: Data
}

struct GatewayOperationalNotice: Equatable {
    let code: String
    let message: String
}

/// Recovered failures are still product-visible state. Gateway responses use
/// `meta.notices`; client-side Cloud→BYOK switches publish through the same
/// center so every transient panel renders one consistent warning.
@MainActor
final class OperationalNoticeCenter: ObservableObject {
    static let shared = OperationalNoticeCenter()

    @Published private(set) var current: GatewayOperationalNotice?

    private init() {}

    func beginOperation(preservingCodes: Set<String> = []) {
        if let current {
            let activeCodes = Set(current.code.split(separator: ",").map(String.init))
            if !preservingCodes.isDisjoint(with: activeCodes) { return }
        }
        current = nil
    }

    func dismiss() {
        current = nil
    }

    func publish(code: String, message: String) {
        guard let current else {
            self.current = GatewayOperationalNotice(code: code, message: message)
            return
        }
        guard !current.message.components(separatedBy: "\n").contains(message) else { return }
        self.current = GatewayOperationalNotice(
            code: [current.code, code].joined(separator: ","),
            message: [current.message, message].joined(separator: "\n")
        )
    }

    func capture(from root: [String: Any]) {
        guard
            let meta = root["meta"] as? [String: Any],
            let rawNotices = meta["notices"] as? [[String: Any]]
        else { return }
        let notices = rawNotices.compactMap { notice -> GatewayOperationalNotice? in
            guard
                let code = notice["code"] as? String,
                let message = notice["message"] as? String,
                !message.isEmpty
            else { return nil }
            return GatewayOperationalNotice(code: code, message: message)
        }
        guard !notices.isEmpty else { return }
        publish(
            code: notices.map(\.code).joined(separator: ","),
            message: notices.map(\.message).joined(separator: "\n")
        )
    }
}

/// The single gateway transport (foundation rebuild Phase 2,
/// docs/foundation-rebuild-plan.md). Owns what every feature client used to
/// copy: availability gating, the request envelope, JSON/multipart sends,
/// transport/status/error-contract mapping, and SSE framing. Feature clients
/// (review/vision/transcribe/account/navigate/memory) are thin wrappers that
/// keep only their domain payloads and response decoding.
struct GatewayClient {
    let api: GatewayAPI
    private let session: URLSession

    /// Usable only when the gateway URL is configured and a user is signed in.
    static func make(session: URLSession = .shared) -> GatewayClient? {
        guard let api = GatewayAPI.make() else { return nil }
        return GatewayClient(api: api, session: session)
    }

    init(api: GatewayAPI, session: URLSession = .shared) {
        self.api = api
        self.session = session
    }

    // MARK: - Envelope (docs/api-contract.md)

    /// The standard request body: request_id / operation / input / client,
    /// plus optional preferences and operation-specific top-level fields.
    static func envelope(
        operation: String,
        input: [String: Any],
        language: OutputLanguage? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "request_id": UUID().uuidString,
            "operation": operation,
            "input": input,
            "client": GatewayAPI.clientPayload(),
        ]
        if let language {
            body["preferences"] = ["output_language": language.rawValue]
        }
        for (key, value) in extra {
            body[key] = value
        }
        return body
    }

    /// `input.context` payload shared by review/vision/distill. The gateway
    /// builds the prompt from it and stores nothing (see the API contract).
    static func contextPayload(_ context: SituationalContext) -> [String: Any] {
        var payload: [String: Any] = ["app_name": context.appName]
        if let title = context.windowTitle { payload["window_title"] = title }
        if let excerpt = context.conversationExcerpt { payload["conversation_excerpt"] = excerpt }
        return payload
    }

    /// `input.memory` payload shared by review/vision. Nil when there is
    /// nothing to inject, so callers can skip the key entirely.
    static func memoryPayload(_ memory: MemoryInjection) -> [String: Any]? {
        var payload: [String: Any] = [:]
        if let persona = memory.personaMD { payload["persona_md"] = persona }
        if let subject = memory.relationshipSubject { payload["relationship_subject"] = subject }
        if let relationship = memory.relationshipMD { payload["relationship_md"] = relationship }
        return payload.isEmpty ? nil : payload
    }

    // MARK: - Plain requests

    /// GET; returns the raw body after transport/status/error mapping.
    func get(_ path: String) async throws -> Data {
        let request = try await api.authorizedRequest(path, method: "GET")
        let data = try await send(request)
        await captureOperationalNotice(from: data)
        return data
    }

    /// JSON-body request; returns the raw body after transport/status/error mapping.
    func postJSON(_ path: String, method: String = "POST", body: [String: Any]) async throws -> Data {
        var request = try await api.authorizedRequest(path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        await captureOperationalNotice(from: data)
        return data
    }

    /// Pre-encoded JSON body (Codable payloads like memory-card sync).
    func sendJSONData(_ path: String, method: String = "POST", body: Data) async throws -> Data {
        var request = try await api.authorizedRequest(path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        let data = try await send(request)
        await captureOperationalNotice(from: data)
        return data
    }

    /// Multipart form body (ASR uploads).
    func postMultipart(_ path: String, boundary: String, body: Data) async throws -> Data {
        var request = try await api.authorizedRequest(path)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try await send(request)
        await captureOperationalNotice(from: data)
        return data
    }

    /// Decodes the response root object, or throws the shared decoding error.
    static func rootObject(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("unexpected gateway response shape")
        }
        return root
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.http(status: -1, body: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.http(status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayAPI.error(status: http.statusCode, data: data)
        }
        return data
    }

    private func captureOperationalNotice(from data: Data) async {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        await OperationalNoticeCenter.shared.capture(from: root)
    }

    // MARK: - SSE

    /// JSON-body request answered as an SSE stream. Yields one event per
    /// `data:` line (the gateway sends exactly one per event, so dispatch is
    /// on the data line — no reliance on blank separators, which
    /// AsyncLineSequence may swallow). `error` events become thrown errors;
    /// non-JSON data lines are skipped. Error responses before the stream
    /// starts are plain JSON; a bounded amount is read for the message.
    func postSSE(_ path: String, body: [String: Any]) async throws -> AsyncThrowingStream<GatewaySSEEvent, Error> {
        var request = try await api.authorizedRequest(path)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ProviderError.http(status: -1, body: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.http(status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 4096 { break }
            }
            throw GatewayAPI.error(status: http.statusCode, data: data)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var eventName = ""
                do {
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            eventName = line.dropFirst("event:".count)
                                .trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        guard
                            let data = payload.data(using: .utf8),
                            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if eventName == "error" {
                            throw GatewayAPI.error(status: 502, data: data)
                        }
                        await OperationalNoticeCenter.shared.capture(from: root)
                        continuation.yield(GatewaySSEEvent(name: eventName, json: root, data: data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
