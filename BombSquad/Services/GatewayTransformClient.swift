import Foundation

struct GatewayTransformClient: TransformProvider {
    private let client: GatewayClient

    static func make() -> GatewayTransformClient? {
        guard let client = GatewayClient.make() else { return nil }
        return GatewayTransformClient(client: client)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    func interpret(
        receivedText: String,
        instruction: String?,
        language: OutputLanguage,
        context: SituationalContext?
    ) async throws -> TransformInterpretationResult {
        var input: [String: Any] = ["text": receivedText]
        addCommonFields(to: &input, instruction: instruction, context: context)
        return try await send(input: input, language: language)
    }

    private func addCommonFields(
        to input: inout [String: Any],
        instruction: String?,
        context: SituationalContext?
    ) {
        if let instruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            input["instruction"] = instruction
        }
        // Same payload shape as ai/review: the gateway builds the prompt and
        // stores no part of it (see the API contract).
        if let context {
            input["context"] = GatewayClient.contextPayload(context)
        }
    }

    private func send(
        input: [String: Any],
        language: OutputLanguage
    ) async throws -> TransformInterpretationResult {
        let data = try await client.postJSON(
            "ai/transform",
            body: GatewayClient.envelope(operation: "transform", input: input, language: language)
        )

        let root = try GatewayClient.rootObject(data)
        guard let result = root["result"] else {
            throw ProviderError.decoding("unexpected gateway response shape")
        }

        do {
            let resultData = try JSONSerialization.data(withJSONObject: result)
            var interpretation = try TransformInterpretationResult.decodeFlexible(from: resultData)
            let meta = root["meta"] as? [String: Any]
            interpretation.modelID = meta?["model_id"] as? String
            return interpretation
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }
}
