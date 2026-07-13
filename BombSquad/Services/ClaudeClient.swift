import Foundation

/// Claude-backed `ReviewProvider`.
/// Uses the Messages API with a single forced tool call so the response is
/// always well-structured JSON we can decode into `ReviewResult`.
struct ClaudeClient: ReviewProvider {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model: String
    private let session: URLSession

    init(model: String = "claude-sonnet-4-6", session: URLSession = .shared) {
        self.model = model
        self.session = session
    }

    func review(
        draft: String,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) async throws -> ReviewResult {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.emptyDraft }
        guard let apiKey = KeychainStore.apiKey(account: APIVendor.anthropic.keychainAccount) else {
            throw ProviderError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(
                draft: trimmed, language: language, context: context, memory: memory
            )
        )

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
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.http(status: http.statusCode, body: String(body.prefix(500)))
        }

        return try decodeResult(from: data)
    }

    // MARK: - Request

    private func requestBody(
        draft: String,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) -> [String: Any] {
        let system = ReviewPrompt.enrichedSystem(base: ReviewPrompt.system, memory: memory)
        var userText = "次の下書きをレビューしてください:\n\n\(draft)"
        if let context {
            userText = ReviewPrompt.contextBlock(context) + "\n\n" + userText
        }
        userText += "\n\n" + ReviewPrompt.languageInstruction(language)
        return [
            "model": model,
            "max_tokens": 2048,
            "system": system,
            "tools": [reviewTool],
            "tool_choice": ["type": "tool", "name": "submit_review"],
            "messages": [
                ["role": "user", "content": userText],
            ],
        ]
    }

    /// Tool schema mirrors `ReviewResult` so decoding is exact.
    private var reviewTool: [String: Any] {
        [
            "name": "submit_review",
            "description": "下書きのレビュー結果を構造化して返す。",
            "input_schema": [
                "type": "object",
                "properties": [
                    "issues": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "category": ["type": "string", "enum": ["typo", "impoliteness", "unclear"]],
                                "severity": ["type": "string", "enum": ["low", "medium", "high"]],
                                "excerpt": ["type": "string", "description": "該当する原文の箇所"],
                                "explanation": ["type": "string", "description": "なぜ問題かの説明（日本語）"],
                                "suggestion": ["type": "string", "description": "どう直すか"],
                            ],
                            "required": ["category", "severity", "excerpt", "explanation", "suggestion"],
                        ],
                    ],
                    "revised_text": ["type": "string", "description": "そのまま送れる修正後の全文"],
                    "summary": ["type": "string", "description": "一言サマリ"],
                ],
                "required": ["issues", "revised_text", "summary"],
            ],
        ]
    }

    // MARK: - Response

    private func decodeResult(from data: Data) throws -> ReviewResult {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = root["content"] as? [[String: Any]]
        else {
            throw ProviderError.decoding("unexpected response shape")
        }

        guard
            let toolBlock = content.first(where: { ($0["type"] as? String) == "tool_use" }),
            let input = toolBlock["input"]
        else {
            throw ProviderError.noStructuredOutput
        }

        do {
            let inputData = try JSONSerialization.data(withJSONObject: input)
            return try JSONDecoder().decode(ReviewResult.self, from: inputData)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }
}
