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
/// configured. Transport/SSE/error plumbing lives in `GatewayClient`.
struct GatewayReviewClient: ReviewProvider {
    private let client: GatewayClient

    /// Usable only when the gateway URL is configured and a user is signed in.
    static func make() -> GatewayReviewClient? {
        guard let client = GatewayClient.make() else { return nil }
        return GatewayReviewClient(client: client)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    func review(
        draft: String,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) async throws -> ReviewResult {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.emptyDraft }

        let data = try await client.postJSON(
            "ai/review",
            body: requestBody(draft: trimmed, language: language, context: context, memory: memory)
        )
        return try decodeResult(from: data)
    }

    /// Streaming review over SSE. Yields `delta` events with revised_text
    /// increments, then one `result` event; the first token typically arrives
    /// well under a second, which is what makes rich models feel instant.
    func reviewStream(
        draft: String,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) async throws -> AsyncThrowingStream<ReviewStreamEvent, Error> {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.emptyDraft }

        var body = requestBody(draft: trimmed, language: language, context: context, memory: memory)
        body["stream"] = true
        let events = try await client.postSSE("ai/review", body: body)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        switch event.name {
                        case "delta":
                            if let text = event.json["text"] as? String, !text.isEmpty {
                                continuation.yield(.delta(text))
                            }
                        case "result":
                            GatewayAPI.captureQuota(fromResponseRoot: event.json)
                            guard let result = event.json["result"] else {
                                throw ProviderError.decoding("stream result had no payload")
                            }
                            let resultData = try JSONSerialization.data(withJSONObject: result)
                            let parsed = try JSONDecoder().decode(ReviewResult.self, from: resultData)
                            continuation.yield(.result(parsed))
                        default:
                            break
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

    // MARK: - Request

    private func requestBody(
        draft: String,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) -> [String: Any] {
        var input: [String: Any] = ["draft": draft]
        if let context {
            input["context"] = GatewayClient.contextPayload(context)
        }
        if let memory, let payload = GatewayClient.memoryPayload(memory) {
            input["memory"] = payload
        }
        return GatewayClient.envelope(
            operation: "review",
            input: input,
            language: language,
            extra: ["mode": "compose"]
        )
    }

    // MARK: - Response

    private func decodeResult(from data: Data) throws -> ReviewResult {
        let root = try GatewayClient.rootObject(data)
        guard let result = root["result"] else {
            throw ProviderError.decoding("unexpected gateway response shape")
        }
        GatewayAPI.captureQuota(fromResponseRoot: root)
        do {
            let resultData = try JSONSerialization.data(withJSONObject: result)
            return try JSONDecoder().decode(ReviewResult.self, from: resultData)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }
}
