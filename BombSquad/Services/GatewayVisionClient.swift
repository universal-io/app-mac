import AppKit
import Foundation

struct VisionTurn: Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let role: Role
    let text: String
}

struct ScreenGuidanceContext: Equatable {
    let goal: String
    let previousInstruction: String

    var wirePayload: [String: Any] {
        ["goal": goal, "previous_instruction": previousInstruction]
    }
}

struct VisionResult: Equatable {
    enum Mode: String {
        case observation
        case answer
        case guide
        case clarification
    }

    let mode: Mode
    let message: String
    let observations: [String]
    let uncertainties: [String]
    let targetCandidateID: String?
}

struct VisionMetadata: Equatable {
    let modelVendor: String
    let modelID: String
    let route: String
    let api: String
    let imageDetail: String
    let reasoningEffort: String
    let fallbackUsed: Bool
    let latencyMs: Int
}

struct VisionResponse: Equatable {
    let captureID: UUID
    let result: VisionResult
    /// Display name of the skill the gateway applied to this turn, or nil when
    /// no skill matched the screen. Shown in the panel: a skill never acts
    /// silently.
    let skillName: String?
    let metadata: VisionMetadata
}

struct GatewayVisionClient {
    private static let maxRawImageBytes = 3_000_000

    private let client: GatewayClient

    static func make() -> GatewayVisionClient? {
        guard let client = GatewayClient.make() else { return nil }
        return GatewayVisionClient(client: client)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    func understand(
        attachment: ScreenshotAttachment,
        question: String?,
        turns: [VisionTurn],
        candidates: [VisionObservation.Candidate] = [],
        candidateDiagnostics: VisionObservationCaptureService.Diagnostics? = nil,
        identity: VisionObservationCaptureService.TargetIdentity? = nil,
        selection: VisionSelectionContext? = nil,
        guidanceContext: ScreenGuidanceContext? = nil,
        language: OutputLanguage
    ) async throws -> VisionResponse {
        let encoded = try Self.encodedImage(at: attachment.url)
        var input: [String: Any] = [
            "capture_id": attachment.id.uuidString,
            "image_base64": encoded.data.base64EncodedString(),
            "media_type": encoded.mediaType,
            "turns": turns.map { ["role": $0.role.rawValue, "text": $0.text] },
            "candidates": candidates.map(\.wirePayload),
        ]
        if let candidateDiagnostics {
            input["candidate_diagnostics"] = candidateDiagnostics.wirePayload
        }
        // Identity of the product on screen, so the Gateway can attach that
        // product's skill. Reference data for the prompt only — the Gateway
        // never stores it, which is why it travels here and not in the
        // diagnostics that feed usage.
        if let identity {
            input["context"] = identity.wirePayload
        }
        if let selection,
           let payload = selection.wirePayload(for: attachment) {
            input["selection"] = payload
        }
        if let guidanceContext {
            input["guidance"] = guidanceContext.wirePayload
        }
        if let question = question?.trimmingCharacters(in: .whitespacesAndNewlines),
           !question.isEmpty {
            input["question"] = question
        }

        let body = GatewayClient.envelope(
            operation: "vision",
            input: input,
            language: language
        )
        let data = try await client.postJSON("ai/vision", body: body)
        return try Self.decode(data, expectedCaptureID: attachment.id)
    }

    private static func encodedImage(at url: URL) throws -> (data: Data, mediaType: String) {
        let source = try Data(contentsOf: url)
        guard source.count > maxRawImageBytes else {
            return (source, url.pathExtension.lowercased() == "jpg" ? "image/jpeg" : "image/png")
        }
        guard
            let bitmap = NSBitmapImageRep(data: source),
            let jpeg = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.9]
            )
        else {
            throw ProviderError.decoding("The captured image exceeds the Gateway limit.")
        }
        return (jpeg, "image/jpeg")
    }

    private static func decode(
        _ data: Data,
        expectedCaptureID: UUID
    ) throws -> VisionResponse {
        let root = try GatewayClient.rootObject(data)
        guard
            let rawCaptureID = root["capture_id"] as? String,
            let captureID = UUID(uuidString: rawCaptureID),
            captureID == expectedCaptureID,
            let resultObject = root["result"] as? [String: Any],
            let rawMode = resultObject["mode"] as? String,
            let mode = VisionResult.Mode(rawValue: rawMode),
            let message = resultObject["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let observations = resultObject["observations"] as? [String],
            let uncertainties = resultObject["uncertainties"] as? [String],
            let meta = root["meta"] as? [String: Any],
            let route = meta["route"] as? String,
            let modelVendor = meta["model_vendor"] as? String,
            let modelID = meta["model_id"] as? String,
            let api = meta["api"] as? String,
            let imageDetail = meta["image_detail"] as? String,
            let reasoningEffort = meta["reasoning_effort"] as? String,
            let fallbackUsed = meta["fallback_used"] as? Bool,
            let latencyMs = meta["latency_ms"] as? Int
        else {
            throw ProviderError.decoding("The Vision response did not match its contract.")
        }
        let targetCandidateID = resultObject["target_candidate_id"] as? String
        let skill = resultObject["skill"] as? [String: Any]
        let skillName = (skill?["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !modelVendor.isEmpty,
            !modelID.isEmpty,
            !api.isEmpty,
            imageDetail == "original",
            reasoningEffort == "none",
            route == "snapshot_vlm"
        else {
            throw ProviderError.decoding(
                "The Vision response used an invalid model configuration."
            )
        }

        return VisionResponse(
            captureID: captureID,
            result: VisionResult(
                mode: mode,
                message: message,
                observations: observations,
                uncertainties: uncertainties,
                targetCandidateID: targetCandidateID
            ),
            skillName: (skillName?.isEmpty ?? true) ? nil : skillName,
            metadata: VisionMetadata(
                modelVendor: modelVendor,
                modelID: modelID,
                route: route,
                api: api,
                imageDetail: imageDetail,
                reasoningEffort: reasoningEffort,
                fallbackUsed: fallbackUsed,
                latencyMs: latencyMs
            )
        )
    }

}
