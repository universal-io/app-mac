#if DEBUG
import Foundation

/// Temporary, authenticated Gateway client. The TypeSafe key never enters the app.
struct GatewayJevClient {
    struct Result: Decodable {
        let choice: String
        let confidence: Double
        let probabilities: [String: Double]
        let model: String
        let inputTokens: Int
        let providerMs: Int
        enum CodingKeys: String, CodingKey {
            case choice, confidence, probabilities, model
            case inputTokens = "input_tokens", providerMs = "provider_ms"
        }
    }
    struct Response: Decodable {
        let snapshotID: UUID
        let result: Result
        enum CodingKeys: String, CodingKey { case snapshotID = "snapshot_id", result }
    }

    static func suggest(
        snapshotID: UUID, goal: String, previousInstruction: String,
        turns: [VisionTurn], candidates: [VisionObservation.Candidate],
        environment: AppEnvironmentSnapshot?
    ) async throws -> Result {
        guard let client = GatewayClient.make() else {
            throw ProviderError.gateway(message: "Jev実験にはログインが必要です。", code: nil)
        }
        var input: [String: Any] = [
            "snapshot_id": snapshotID.uuidString,
            "goal": goal,
            "previous_instruction": String(previousInstruction.prefix(4_000)),
            "turns": turns.suffix(20).map { ["role": $0.role.rawValue, "text": String($0.text.prefix(4_000))] },
            "candidates": candidates.map { candidate -> [String: Any] in
                var payload = candidate.wirePayload
                payload.removeValue(forKey: "rect")
                payload.removeValue(forKey: "source")
                return payload
            },
        ]
        if let environment {
            var context = environment.wirePayload
            context.removeValue(forKey: "url")
            input["context"] = context
        }
        let body = GatewayClient.envelope(operation: "jev_candidates", input: input)
        let data = try await client.postJSON("ai/jev-candidates", body: body, timeout: 20)
        let response = try JSONDecoder().decode(Response.self, from: data)
        let result = response.result
        let expected = Set(candidates.map(\.id) + ["none"])
        guard response.snapshotID == snapshotID,
              Set(result.probabilities.keys) == expected,
              expected.contains(result.choice),
              result.confidence.isFinite, (0...1).contains(result.confidence),
              result.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(result.probabilities.values.reduce(0, +) - 1) <= 0.02,
              let selected = result.probabilities[result.choice],
              result.probabilities.values.allSatisfy({ $0 <= selected + 0.000001 }),
              result.inputTokens >= 0, result.providerMs >= 0 else {
            throw ProviderError.decoding("Jevの候補応答が取得した状態と一致しません。")
        }
        return result
    }
}
#endif
