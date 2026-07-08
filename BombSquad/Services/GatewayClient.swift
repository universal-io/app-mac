import Foundation

/// Latest quota envelope returned by the gateway (docs/api-contract.md).
/// Updated by gateway clients on each successful review; shown on my page.
struct GatewayQuota: Codable, Equatable {
    let plan: String
    let used: Int
    // null on the wire for plans with no cap (bs_plans.monthly_usage_limit is
    // null = unlimited; foundation-redesign-plan §5-c). Free-tier stays a number.
    let limit: Int?
    let remaining: Int?
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case plan, used, limit, remaining
        case resetsAt = "resets_at"
    }
}

/// Publishes the most recent quota seen on any gateway response so the
/// management window can show usage without an extra request.
final class GatewayQuotaStore: ObservableObject {
    static let shared = GatewayQuotaStore()
    @Published private(set) var latest: GatewayQuota?

    private init() {}

    func update(_ quota: GatewayQuota) {
        DispatchQueue.main.async { self.latest = quota }
    }

    func clear() {
        DispatchQueue.main.async { self.latest = nil }
    }
}

/// The single place that answers "is the gateway usable right now?":
/// a gateway base URL is configured and a user is signed in. Every feature
/// client's `make()` factory delegates here, so the BYOK fallback decision
/// (gateway unavailable → direct provider clients) has exactly one source.
enum EngineResolver {
    static func gateway() -> GatewayClient? {
        let config = BombSquadConfig.snapshot()
        guard
            let raw = config.apiBaseURL.value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw),
            BombSquadAuthClient.shared.currentSession() != nil
        else { return nil }
        return GatewayClient(baseURL: url)
    }
}

/// Core HTTP client for the product gateway (docs/api-contract.md). Owns the
/// plumbing every feature client shares: endpoint building, bearer auth,
/// the client payload, JSON and SSE request helpers, and the error contract
/// mapping. Feature clients (review / vision / navigate / transcribe /
/// account) are thin typed wrappers over this type.
struct GatewayClient {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Endpoint and auth

    /// `BOMB_SQUAD_API_BASE_URL` may or may not include the `/api` base path.
    /// `path` is relative to `/api` (e.g. "ai/review").
    func endpoint(_ path: String) -> URL {
        let full = baseURL.path.hasSuffix("/api") ? path : "api/\(path)"
        return baseURL.appendingPathComponent(full)
    }

    func authorizedRequest(_ path: String, method: String = "POST") async throws -> URLRequest {
        let token = try await BombSquadAuthClient.shared.accessToken()
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func clientPayload() -> [String: Any] {
        let bundle = Bundle.main
        return [
            "platform": "macos",
            "app_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            "build_number": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
        ]
    }

    // MARK: - Plain requests

    /// Sends a prepared request, maps transport failures and the gateway
    /// error contract, and returns the body of a 2xx response.
    func send(_ request: URLRequest) async throws -> Data {
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
            throw Self.error(status: http.statusCode, data: data)
        }
        return data
    }

    /// POST with a JSON body; returns the parsed root object of the response.
    func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = try await authorizedRequest(path)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("unexpected gateway response shape")
        }
        return root
    }

    // MARK: - SSE streaming

    /// One parsed server-sent event: the gateway sends exactly one `data:`
    /// line per event, so events are dispatched on the data line (no reliance
    /// on blank separators, which AsyncLineSequence may swallow).
    struct SSEEvent {
        let name: String
        /// Parsed JSON object of the `data:` line.
        let root: [String: Any]
        /// Raw bytes of the `data:` line (for error mapping / re-decoding).
        let data: Data
    }

    /// POST with a JSON body over SSE. Handles the status check (error
    /// responses are plain JSON; a bounded amount is read for the message),
    /// line/event parsing, and gateway `error` events (thrown). `transform`
    /// turns each remaining event into a typed value; nil skips the event.
    func postSSE<T>(
        _ path: String,
        body: [String: Any],
        transform: @escaping (SSEEvent) throws -> T?
    ) async throws -> AsyncThrowingStream<T, Error> {
        var request = try await authorizedRequest(path)
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
            throw Self.error(status: http.statusCode, data: data)
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
                            throw Self.error(status: 502, data: data)
                        }
                        let event = SSEEvent(name: eventName, root: root, data: data)
                        if let value = try transform(event) {
                            continuation.yield(value)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Response envelope

    /// Pulls the quota envelope out of a successful gateway response body and
    /// publishes it for the management window.
    static func captureQuota(fromResponseRoot root: [String: Any]) {
        guard
            let quotaObject = root["quota"],
            let data = try? JSONSerialization.data(withJSONObject: quotaObject),
            let quota = try? JSONDecoder().decode(GatewayQuota.self, from: data)
        else { return }
        GatewayQuotaStore.shared.update(quota)
    }

    /// Maps the gateway error contract to user-facing messages.
    static func error(status: Int, data: Data) -> Error {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errorObject = root["error"] as? [String: Any],
            let code = errorObject["code"] as? String
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            return ProviderError.http(status: status, body: String(body.prefix(500)))
        }

        let message: String
        switch code {
        case "UNAUTHENTICATED":
            message = "ログインの有効期限が切れました。アカウントから再ログインしてください。"
        case "QUOTA_EXCEEDED":
            message = "今月の利用枠を使い切りました。来月のリセットをお待ちいただくか、プランをご検討ください。"
        case "PAYMENT_REQUIRED":
            message = "現在のプランではこの操作を利用できません。"
        case "PROVIDER_ERROR":
            // The gateway already produces a user-facing Japanese message
            // (rate-limit guidance vs. generic failure); show it as-is.
            message = (errorObject["message"] as? String)
                ?? "AI エンジン側で一時的なエラーが発生しました。少し待ってから再試行してください。"
        default:
            message = (errorObject["message"] as? String) ?? "サーバーエラーが発生しました。"
        }
        return ProviderError.gateway(message: message)
    }
}
