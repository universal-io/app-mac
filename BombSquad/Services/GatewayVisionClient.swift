import AppKit
import Foundation

/// Screenshot interpretation via the product gateway (POST /api/ai/vision).
/// The server owns the OpenAI key and the prompt; usage is metered per
/// tenant. The BYOK OpenAIVisionClient remains as a developer fallback.
/// Transport/error plumbing lives in `GatewayClient`.
struct GatewayVisionClient: VisionProvider {
    /// The gateway rejects payloads past ~4MB of base64 (Vercel body limit);
    /// re-encode large PNG screenshots as JPEG before sending.
    private static let maxRawImageBytes = 3_000_000

    private let client: GatewayClient

    static func make() -> GatewayVisionClient? {
        guard let client = GatewayClient.make() else { return nil }
        return GatewayVisionClient(client: client)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    func interpret(
        imageURL: URL,
        instruction: String?,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) async throws -> VisionInterpretationResult {
        let imageData = try Data(contentsOf: imageURL)
        var payloadData = imageData
        var mediaType = "image/png"
        if payloadData.count > Self.maxRawImageBytes,
           let jpeg = Self.jpegData(from: imageData) {
            payloadData = jpeg
            mediaType = "image/jpeg"
        }

        var input: [String: Any] = [
            "image_base64": payloadData.base64EncodedString(),
            "media_type": mediaType,
        ]
        addCommonFields(to: &input, instruction: instruction, context: context, memory: memory)
        return try await send(input: input, language: language)
    }

    /// M4-B receiving side: interpret a received message with the same
    /// schema/prompt family as a screenshot (`input.text` on the gateway).
    func interpret(
        receivedText: String,
        instruction: String?,
        language: OutputLanguage,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) async throws -> VisionInterpretationResult {
        var input: [String: Any] = ["text": receivedText]
        addCommonFields(to: &input, instruction: instruction, context: context, memory: memory)
        return try await send(input: input, language: language)
    }

    private func addCommonFields(
        to input: inout [String: Any],
        instruction: String?,
        context: SituationalContext?,
        memory: MemoryInjection?
    ) {
        if let instruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            input["instruction"] = instruction
        }
        // Same payload shapes as ai/review: the gateway builds the prompt and
        // stores neither block (see the API contract).
        if let context {
            input["context"] = GatewayClient.contextPayload(context)
        }
        if let memory, let payload = GatewayClient.memoryPayload(memory) {
            input["memory"] = payload
        }
    }

    private func send(
        input: [String: Any],
        language: OutputLanguage
    ) async throws -> VisionInterpretationResult {
        let data = try await client.postJSON(
            "ai/vision",
            body: GatewayClient.envelope(operation: "vision", input: input, language: language)
        )

        let root = try GatewayClient.rootObject(data)
        guard let result = root["result"] else {
            throw ProviderError.decoding("unexpected gateway response shape")
        }

        do {
            let resultData = try JSONSerialization.data(withJSONObject: result)
            var interpretation = try VisionInterpretationResult.decodeFlexible(from: resultData)
            let meta = root["meta"] as? [String: Any]
            interpretation.modelID = meta?["model_id"] as? String
            return interpretation
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }

    private static func jpegData(from imageData: Data) -> Data? {
        guard let bitmap = NSBitmapImageRep(data: imageData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
