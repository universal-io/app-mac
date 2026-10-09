import Foundation

/// R18: asks the Gateway for a single-use Gemini Live token. The setup that
/// comes back is sent verbatim as the first WebSocket message; the token has
/// it locked in, so nothing in the app names the model or holds the persona
/// (api-gateway `docs/api-contract.md` POST /ai/live-token).
struct CompanionTokenClient {
    struct Grant {
        let token: String
        /// The `setup` message body, exactly as the Gateway locked it.
        let setup: [String: Any]
    }

    let client: GatewayClient

    /// Nil when signed out, like every other Gateway client.
    static func make() -> CompanionTokenClient? {
        GatewayClient.make().map(CompanionTokenClient.init(client:))
    }

    /// `handle` resumes the conversation it came from: the handle is part of
    /// the locked setup, so every reconnect needs a token of its own.
    func grant(handle: String?, voice: String) async throws -> Grant {
        // "client": the server's own turn detection off; this app sends
        // activityStart/activityEnd (`CompanionTurnTaker`). "async": looks
        // are answered at once and the eye's answer follows as a turn
        // (`CompanionSession.lookAcknowledgement`).
        var input: [String: Any] = ["voice": voice, "turns": "client", "look": "async"]
        if let handle { input["handle"] = handle }
        let body = GatewayClient.envelope(operation: "live_token", input: input)
        let data = try await client.postJSON(
            "ai/live-token",
            body: body,
            timeout: OperationDeadline.accountRequest
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let token = result["token"] as? String, token.hasPrefix("auth_tokens/"),
              let setup = result["setup"] as? [String: Any]
        else {
            throw ProviderError.decoding("声の相棒の接続情報を読めませんでした。")
        }
        return Grant(token: token, setup: setup)
    }
}
