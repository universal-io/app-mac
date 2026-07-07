import Foundation

/// LLM calls that build and grow memory cards. The production path goes
/// through the gateway (POST /api/ai/memory/distill); the BYOK Groq direct
/// call remains as a developer fallback. Memory work happens off the review
/// hot path, so a failed call must never surface as a user-facing error
/// (except in the explicit bootstrap flow, which reports).
enum MemoryDistiller {
    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private static let modelID = "openai/gpt-oss-120b"

    enum DistillerError: LocalizedError {
        case missingAPIKey
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Groq API キーが未設定です。設定から登録してください。"
            case .badResponse(let detail):
                return "プロファイル生成に失敗しました: \(detail)"
            }
        }
    }

    // MARK: - Bootstrap (onboarding)

    /// Generate a persona card from pasted past messages. Throws so the
    /// onboarding UI can show what went wrong.
    static func generatePersonaCard(fromSamples samples: String) async throws -> String {
        let content: String
        if let client = EngineResolver.gateway() {
            let result = try await gatewayCall(
                client: client,
                operation: "bootstrap",
                input: ["samples": samples]
            )
            content = result["persona_md"] as? String ?? ""
        } else {
            let user = "以下はユーザーが過去に実際に送ったメッセージのサンプルです。スタイルプロファイルを作成してください。\n\n\(samples)"
            content = try await chat(system: PersonaPrompt.bootstrapSystem, user: user, jsonMode: false)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DistillerError.badResponse("empty result") }
        return trimmed
    }

    // MARK: - Post-deploy distillation

    /// Observe one deploy (original → suggestion → final) and append any
    /// high-confidence notes to the memory cards. Fire-and-forget: failures
    /// are logged, never shown.
    static func distillAfterDeploy(
        original: String,
        suggestion: String,
        final: String,
        context: SituationalContext?
    ) async {
        do {
            let root: [String: Any]
            if let client = EngineResolver.gateway() {
                var input: [String: Any] = [
                    "original": original,
                    "suggestion": suggestion,
                    "final": final,
                ]
                if let context {
                    var contextPayload: [String: Any] = ["app_name": context.appName]
                    if let title = context.windowTitle { contextPayload["window_title"] = title }
                    if let excerpt = context.conversationExcerpt { contextPayload["conversation_excerpt"] = excerpt }
                    input["context"] = contextPayload
                }
                root = try await gatewayCall(client: client, operation: "distill", input: input)
            } else {
                let user = PersonaPrompt.distillUser(
                    original: original, suggestion: suggestion, final: final, context: context
                )
                let content = try await chat(system: PersonaPrompt.distillSystem, user: user, jsonMode: true)
                guard
                    let jsonData = extractJSON(from: content),
                    let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                else { return }
                root = parsed
            }

            if let note = nonEmptyString(root["persona_note"]) {
                try await MemoryStore.shared.appendPersonaNote(note)
            }
            if let subject = nonEmptyString(root["relationship_subject"]),
               let note = nonEmptyString(root["relationship_note"]) {
                try await MemoryStore.shared.appendRelationshipNote(subject: subject, note: note)
            }
        } catch {
            NSLog("BombSquad memory distillation skipped: \(error.localizedDescription)")
        }
    }

    // MARK: - Gateway call

    /// Calls POST /api/ai/memory/distill and returns the `result` object.
    private static func gatewayCall(
        client: GatewayClient,
        operation: String,
        input: [String: Any]
    ) async throws -> [String: Any] {
        var request = try await client.authorizedRequest("ai/memory/distill")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": UUID().uuidString,
            "operation": operation,
            "input": input,
            "client": GatewayClient.clientPayload(),
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DistillerError.badResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayClient.error(status: http.statusCode, data: data)
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any]
        else {
            throw DistillerError.badResponse("unexpected gateway response shape")
        }
        return result
    }

    // MARK: - BYOK fallback chat call

    private static func chat(system: String, user: String, jsonMode: Bool) async throws -> String {
        guard let apiKey = KeychainStore.apiKey(account: APIVendor.groq.keychainAccount) else {
            throw DistillerError.missingAPIKey
        }

        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": 2048,
            "reasoning_effort": "low",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DistillerError.badResponse("HTTP \(status) \(String(body.prefix(200)))")
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw DistillerError.badResponse("unexpected response shape")
        }
        return content
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
    }

    /// Tolerates reasoning blocks or stray prose around the JSON object.
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
