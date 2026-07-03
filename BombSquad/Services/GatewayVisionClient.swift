import AppKit
import Foundation

/// Screenshot interpretation via the product gateway (POST /api/ai/vision).
/// The server owns the OpenAI key and the prompt; usage is metered per
/// tenant. The BYOK OpenAIVisionClient remains as a developer fallback.
struct GatewayVisionClient: VisionProvider {
    /// The gateway rejects payloads past ~4MB of base64 (Vercel body limit);
    /// re-encode large PNG screenshots as JPEG before sending.
    private static let maxRawImageBytes = 3_000_000

    private let api: GatewayAPI
    private let session: URLSession

    static func make() -> GatewayVisionClient? {
        guard let api = GatewayAPI.make() else { return nil }
        return GatewayVisionClient(api: api)
    }

    init(api: GatewayAPI, session: URLSession = .shared) {
        self.api = api
        self.session = session
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
        if let instruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            input["instruction"] = instruction
        }
        // Same payload shapes as ai/review: the gateway builds the prompt and
        // stores neither block (see the API contract).
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

        var request = try await api.authorizedRequest("ai/vision")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": UUID().uuidString,
            "operation": "vision",
            "input": input,
            "preferences": ["output_language": language.rawValue],
            "client": GatewayAPI.clientPayload(),
        ])

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
            throw GatewayAPI.error(status: http.statusCode, data: data)
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"]
        else {
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
