import Foundation

/// LLM calls that build and grow memory cards through the product Gateway.
/// Memory work happens off the review
/// hot path, so a failed call must never surface as a user-facing error
/// that blocks sending. The shared operational notice may still report it.
enum MemoryDistiller {
    enum DistillerError: LocalizedError {
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let detail):
                return "プロファイル生成に失敗しました: \(detail)"
            }
        }
    }

    // MARK: - Bootstrap (onboarding)

    /// Generate a persona card from pasted past messages. Throws so the
    /// onboarding UI can show what went wrong.
    static func generatePersonaCard(fromSamples samples: String) async throws -> String {
        guard let client = GatewayClient.make() else {
            throw DistillerError.badResponse("ログイン状態を確認してください")
        }
        let result = try await gatewayCall(
            client: client,
            operation: "bootstrap",
            input: ["samples": samples]
        )
        let content = result["persona_md"] as? String ?? ""
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DistillerError.badResponse("empty result") }
        return trimmed
    }

    // MARK: - Post-deploy distillation

    /// Observe one deploy (original → suggestion → final) and append any
    /// high-confidence notes to the memory cards. Fire-and-forget: failures
    /// never block sending and are reported through the shared notice.
    static func distillAfterDeploy(
        original: String,
        suggestion: String,
        final: String,
        context: SituationalContext?
    ) async {
        do {
            guard let client = GatewayClient.make() else { return }
            var input: [String: Any] = [
                "original": original,
                "suggestion": suggestion,
                "final": final,
            ]
            if let context {
                input["context"] = GatewayClient.contextPayload(context)
            }
            let root = try await gatewayCall(client: client, operation: "distill", input: input)

            if let note = nonEmptyString(root["persona_note"]) {
                try await MemoryStore.shared.appendPersonaNote(note)
            }
            if let subject = nonEmptyString(root["relationship_subject"]),
               let note = nonEmptyString(root["relationship_note"]) {
                try await MemoryStore.shared.appendRelationshipNote(subject: subject, note: note)
            }
        } catch {
            NSLog("BombSquad memory distillation skipped: \(error.localizedDescription)")
            await MainActor.run {
                OperationalNoticeCenter.shared.publish(
                    code: "MODEL_ROUTE_FAILED",
                    message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Gateway call

    /// Calls POST /api/ai/memory/distill and returns the `result` object.
    /// Transport/error plumbing lives in `GatewayClient`.
    private static func gatewayCall(
        client: GatewayClient,
        operation: String,
        input: [String: Any]
    ) async throws -> [String: Any] {
        let data = try await client.postJSON(
            "ai/memory/distill",
            body: GatewayClient.envelope(operation: operation, input: input)
        )
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any]
        else {
            throw DistillerError.badResponse("unexpected gateway response shape")
        }
        return result
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
    }

}
