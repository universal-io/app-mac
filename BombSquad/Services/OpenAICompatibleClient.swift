import Foundation

/// `ReviewProvider` for any OpenAI-compatible Chat Completions endpoint.
/// Covers OpenAI and Groq. OpenAI uses strict json_schema structured outputs;
/// Groq uses json_object mode with the schema described in the prompt, which is
/// the most broadly compatible path across Groq's model lineup.
struct OpenAICompatibleClient: ReviewProvider {
    private let endpoint: URL
    private let keychainAccount: String
    private let apiModelID: String
    private let reasoningEffort: String?
    private let useStrictSchema: Bool
    private let session: URLSession

    init(model: ReviewModel, session: URLSession = .shared) {
        guard let endpoint = model.vendor.openAICompatibleEndpoint else {
            fatalError("OpenAICompatibleClient built for non-compatible vendor: \(model.vendor)")
        }
        self.endpoint = endpoint
        self.keychainAccount = model.vendor.keychainAccount
        self.apiModelID = model.apiModelID
        self.reasoningEffort = model.reasoningEffort
        self.useStrictSchema = (model.vendor == .openAI)
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
        guard let apiKey = KeychainStore.apiKey(account: keychainAccount) else {
            throw ProviderError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        var userContent = "次の下書きをレビューしてください:\n\n\(draft)"
        if let context {
            userContent = ReviewPrompt.contextBlock(context) + "\n\n" + userContent
        }
        userContent += "\n\n" + ReviewPrompt.languageInstruction(language)

        var body: [String: Any] = [
            "model": apiModelID,
            "max_tokens": 4096,
        ]

        if useStrictSchema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "review_result", "strict": true, "schema": Self.schema],
            ]
        } else {
            // json_object mode requires the word "JSON" in the prompt and works
            // best with the shape spelled out explicitly.
            body["response_format"] = ["type": "json_object"]
            userContent += "\n\n" + Self.jsonInstruction
        }

        if let reasoningEffort {
            body["reasoning_effort"] = reasoningEffort
        }

        let system = ReviewPrompt.enrichedSystem(base: ReviewPrompt.system, memory: memory)
        body["messages"] = [
            ["role": "system", "content": system],
            ["role": "user", "content": userContent],
        ]
        return body
    }

    /// Strict Structured Outputs schema (OpenAI): all objects disallow extra
    /// keys and list every property as required.
    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "issues": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "category": ["type": "string", "enum": ["typo", "impoliteness", "unclear"]],
                        "severity": ["type": "string", "enum": ["low", "medium", "high"]],
                        "excerpt": ["type": "string"],
                        "explanation": ["type": "string"],
                        "suggestion": ["type": "string"],
                    ],
                    "required": ["category", "severity", "excerpt", "explanation", "suggestion"],
                ],
            ],
            "revised_text": ["type": "string"],
            "summary": ["type": "string"],
        ],
        "required": ["issues", "revised_text", "summary"],
    ]

    /// Inline schema description for json_object mode (Groq).
    private static let jsonInstruction = """
    出力は次の構造のJSONオブジェクト1つだけで返してください（コードブロックや前後の説明文を付けない）:
    {
      "issues": [
        {"category": "typo|impoliteness|unclear", "severity": "low|medium|high",
         "excerpt": "原文の該当箇所", "explanation": "なぜ問題か", "suggestion": "どう直すか"}
      ],
      "revised_text": "そのまま送れる修正後の全文",
      "summary": "一言サマリ"
    }
    """

    // MARK: - Response

    private func decodeResult(from data: Data) throws -> ReviewResult {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw ProviderError.decoding("unexpected response shape")
        }

        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw ProviderError.decoding("モデルが応答を拒否しました: \(refusal)")
        }

        guard
            let content = message["content"] as? String,
            let jsonData = Self.extractJSON(from: content)
        else {
            throw ProviderError.noStructuredOutput
        }

        do {
            return try JSONDecoder().decode(ReviewResult.self, from: jsonData)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }

    /// Robustly pull the JSON object out of the content, tolerating reasoning
    /// `<think>` blocks, code fences, or stray prose that some models emit.
    private static func extractJSON(from raw: String) -> Data? {
        var text = raw
        if let thinkEnd = text.range(of: "</think>", options: .backwards) {
            text = String(text[thinkEnd.upperBound...])
        }
        guard
            let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            start <= end
        else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }
}
