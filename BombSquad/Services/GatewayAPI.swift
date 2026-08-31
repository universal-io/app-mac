import Foundation

/// Latest quota envelope returned by the gateway (docs/api-contract.md).
/// Updated by gateway clients on each successful review; shown on the account page.
struct GatewayQuota: Codable, Equatable {
    let plan: String
    let used: Int
    /// Nil on a plan with no monthly ceiling. The gateway sends `null` for
    /// those (`quotaInfo`), so a non-optional `Int` here failed the whole
    /// decode and the account page lost its usage row rather than saying
    /// "unlimited".
    let limit: Int?
    let remaining: Int?
    let resetsAt: String

    /// How full the month is, 0...1, or nil when nothing bounds it.
    var fraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(1, Double(used) / Double(limit))
    }

    /// How far past the ceiling this month went. Zero unless a limit was
    /// lowered under a month already spent, which is exactly when the number
    /// needs saying out loud.
    var overage: Int {
        guard let limit else { return 0 }
        return max(0, used - limit)
    }

    var isExhausted: Bool {
        guard let remaining else { return false }
        return remaining == 0
    }

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

/// Shared plumbing for gateway-backed clients: base URL resolution, endpoint
/// building, bearer auth, the client payload, and the error contract mapping
/// (docs/api-contract.md).
struct GatewayAPI {
    let baseURL: URL

    /// Usable only when the gateway URL is configured and a user is signed in.
    static func make() -> GatewayAPI? {
        let baseURL = BombSquadConfig.resolvedAPIBaseURL().flatMap(URL.init(string:))
        guard
            let baseURL,
            BombSquadAuthClient.shared.currentSession() != nil
        else { return nil }
        return GatewayAPI(baseURL: baseURL)
    }

    /// `BOMB_SQUAD_API_BASE_URL` may or may not include the `/api` base path.
    /// `path` is relative to `/api` (e.g. "ai/review").
    func endpoint(_ path: String) -> URL {
        let full = baseURL.path.hasSuffix("/api") ? path : "api/\(path)"
        return baseURL.appendingPathComponent(full)
    }

    /// The single point every gateway request passes through, which makes it
    /// the single place a request can be given a deadline. Both waits here were
    /// unbounded before R11: the session read could hang before any request
    /// existed (leaving no network trace at all), and the request itself had no
    /// `timeoutInterval`, so a connection that never answered never returned.
    func authorizedRequest(
        _ path: String,
        method: String = "POST",
        timeout: TimeInterval = OperationDeadline.accountRequest
    ) async throws -> URLRequest {
        let token = try await withDeadline(
            seconds: OperationDeadline.accessToken,
            operation: "auth.accessToken"
        ) {
            try await BombSquadAuthClient.shared.accessToken()
        }
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
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
            if body.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().hasPrefix("<!doctype html") {
                let message = status == 404
                    ? "必要なGateway APIが本番環境に配備されていません（HTTP 404）。"
                    : "Gatewayから想定外のHTML応答が返されました（HTTP \(status)）。"
                return ProviderError.gateway(message: message, code: nil)
            }
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
        case "REAUTH_REQUIRED":
            message = "安全のため、いったんログアウトして再ログインしてから退会してください。"
        case "PROVIDER_ERROR":
            // The gateway already produces a user-facing Japanese message
            // (rate-limit guidance vs. generic failure); show it as-is.
            message = (errorObject["message"] as? String)
                ?? "AI エンジン側で一時的なエラーが発生しました。少し待ってから再試行してください。"
        default:
            message = (errorObject["message"] as? String) ?? "サーバーエラーが発生しました。"
        }
        return ProviderError.gateway(message: message, code: code)
    }
}
