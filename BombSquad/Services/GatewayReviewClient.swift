import Foundation

/// One event of a streaming review (SSE from the gateway).
enum ReviewStreamEvent {
    /// An increment of `revised_text` as the model produces it.
    case delta(String)
    /// The fully parsed result; always the last event of a successful stream.
    case result(ReviewResult)
}

/// `ReviewProvider` backed by the product gateway (docs/api-contract.md).
/// This is the production path: no LLM provider keys on the device, the
/// server owns prompts/model routing, and usage is metered per tenant.
/// The BYOK clients remain as a developer fallback when no gateway URL is
/// configured.
struct GatewayReviewClient: ReviewProvider {
    private let client: GatewayClient

    /// Usable only when the gateway URL is configured and a user is signed in.
    static func make() -> GatewayReviewClient? {
        EngineResolver.gateway().map(GatewayReviewClient.init)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    func review(
        draft: String,
        mode: ReviewMode,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) async throws -> ReviewResult {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.emptyDraft }

        let root = try await client.postJSON(
            "ai/review",
            body: requestBody(draft: trimmed, mode: mode, language: language, context: context, memory: memory)
        )
        return try decodeResult(fromRoot: root)
    }

    /// Streaming review over SSE. Yields `delta` events with revised_text
    /// increments, then one `result` event; the first token typically arrives
    /// well under a second, which is what makes rich models feel instant.
    func reviewStream(
        draft: String,
        mode: ReviewMode,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) async throws -> AsyncThrowingStream<ReviewStreamEvent, Error> {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.emptyDraft }

        var body = requestBody(draft: trimmed, mode: mode, language: language, context: context, memory: memory)
        body["stream"] = true

        return try await client.postSSE("ai/review", body: body) { event in
            switch event.name {
            case "delta":
                guard let text = event.root["text"] as? String, !text.isEmpty else { return nil }
                return .delta(text)
            case "result":
                GatewayClient.captureQuota(fromResponseRoot: event.root)
                guard let result = event.root["result"] else {
                    throw ProviderError.decoding("stream result had no payload")
                }
                let resultData = try JSONSerialization.data(withJSONObject: result)
                return .result(try JSONDecoder().decode(ReviewResult.self, from: resultData))
            default:
                return nil
            }
        }
    }

    // MARK: - Request

    private func requestBody(
        draft: String,
        mode: ReviewMode,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) -> [String: Any] {
        var input: [String: Any] = ["draft": draft]
        if let context {
            var contextPayload: [String: Any] = ["app_name": context.appName]
            if let title = context.windowTitle { contextPayload["window_title"] = title }
            if let excerpt = context.conversationExcerpt { contextPayload["conversation_excerpt"] = excerpt }
            input["context"] = contextPayload
        }
        if let memory {
            var memoryPayload: [String: Any] = [:]
            if let persona = memory.personaMD { memoryPayload["persona_md"] = persona }
            if let subject = memory.relationshipSubject { memoryPayload["relationship_subject"] = subject }
            if let relationship = memory.relationshipMD { memoryPayload["relationship_md"] = relationship }
            if !memoryPayload.isEmpty { input["memory"] = memoryPayload }
        }

        return [
            "request_id": UUID().uuidString,
            "operation": "review",
            "mode": mode == .transform ? "transform" : "compose",
            "input": input,
            "preferences": [
                "output_language": language.rawValue,
            ],
            "client": GatewayClient.clientPayload(),
        ]
    }

    // MARK: - Response

    private func decodeResult(fromRoot root: [String: Any]) throws -> ReviewResult {
        guard let result = root["result"] else {
            throw ProviderError.decoding("unexpected gateway response shape")
        }
        GatewayClient.captureQuota(fromResponseRoot: root)
        do {
            let resultData = try JSONSerialization.data(withJSONObject: result)
            return try JSONDecoder().decode(ReviewResult.self, from: resultData)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }
}
