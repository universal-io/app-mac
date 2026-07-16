import AppKit
import Foundation

struct ScreenUnderstandingTurn: Equatable {
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

struct ScreenUnderstandingResult: Equatable {
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

struct ScreenUnderstandingMetadata: Equatable {
    let modelVendor: String
    let modelID: String
    let route: String
    let api: String
    let imageDetail: String
    let reasoningEffort: String
    let fallbackUsed: Bool
    let latencyMs: Int
}

struct ScreenUnderstandingResponse: Equatable {
    let captureID: UUID
    let result: ScreenUnderstandingResult
    let metadata: ScreenUnderstandingMetadata
}

/// Isolated Challenge 3 transport. It has no BYOK or legacy model fallback.
struct GatewayScreenUnderstandingClient {
    static let requiredModelID = "gpt-5.6-luna"
    private static let maxRawImageBytes = 3_000_000

    private let client: GatewayClient

    static func make() -> GatewayScreenUnderstandingClient? {
        guard let client = GatewayClient.make() else { return nil }
        return GatewayScreenUnderstandingClient(client: client)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    func understand(
        attachment: ScreenshotAttachment,
        question: String?,
        turns: [ScreenUnderstandingTurn],
        candidates: [VisionObservation.Candidate] = [],
        candidateDiagnostics: VisionObservationCaptureService.Diagnostics? = nil,
        guidanceContext: ScreenGuidanceContext? = nil,
        language: OutputLanguage
    ) async throws -> ScreenUnderstandingResponse {
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
        if let guidanceContext {
            input["guidance"] = guidanceContext.wirePayload
        }
        if let question = question?.trimmingCharacters(in: .whitespacesAndNewlines),
           !question.isEmpty {
            input["question"] = question
        }

        let body = GatewayClient.envelope(
            operation: "screen_understanding",
            input: input,
            language: language
        )
        let requestID = body["request_id"] as? String ?? UUID().uuidString
#if DEBUG
        let replayRequest = Self.replayRequestData(body: body, mediaType: encoded.mediaType)
#endif
        var responseData: Data?
        do {
            let data = try await client.postJSON("ai/screen-understanding", body: body)
            responseData = data
            let response = try Self.decode(data, expectedCaptureID: attachment.id)
#if DEBUG
            await Challenge3ReplayStore.shared.record(
                requestID: requestID,
                request: replayRequest,
                image: encoded.data,
                mediaType: encoded.mediaType,
                response: data,
                error: nil
            )
#endif
            return response
        } catch {
#if DEBUG
            await Challenge3ReplayStore.shared.record(
                requestID: requestID,
                request: replayRequest,
                image: encoded.data,
                mediaType: encoded.mediaType,
                response: responseData,
                error: String(describing: error)
            )
#endif
            throw error
        }
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
            throw ProviderError.decoding("Challenge 3 image exceeds the Gateway limit.")
        }
        return (jpeg, "image/jpeg")
    }

#if DEBUG
    private static func replayRequestData(body: [String: Any], mediaType: String) -> Data? {
        var replayBody = body
        if var input = replayBody["input"] as? [String: Any] {
            input["image_base64"] = mediaType == "image/jpeg" ? "@image.jpg" : "@image.png"
            replayBody["input"] = input
        }
        return try? JSONSerialization.data(
            withJSONObject: replayBody,
            options: [.prettyPrinted, .sortedKeys]
        )
    }
#endif

    private static func decode(
        _ data: Data,
        expectedCaptureID: UUID
    ) throws -> ScreenUnderstandingResponse {
        let root = try GatewayClient.rootObject(data)
        guard
            let rawCaptureID = root["capture_id"] as? String,
            let captureID = UUID(uuidString: rawCaptureID),
            captureID == expectedCaptureID,
            let resultObject = root["result"] as? [String: Any],
            let rawMode = resultObject["mode"] as? String,
            let mode = ScreenUnderstandingResult.Mode(rawValue: rawMode),
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
            throw ProviderError.decoding("Challenge 3 response did not match its contract.")
        }
        let targetCandidateID = resultObject["target_candidate_id"] as? String

        guard
            modelVendor == "openai",
            api == "responses",
            imageDetail == "original",
            reasoningEffort == "none",
            fallbackUsed == false,
            route == "snapshot_vlm",
            modelID == requiredModelID
        else {
            throw ProviderError.decoding(
                "Challenge 3 active model configuration was not used; the turn was rejected."
            )
        }

        return ScreenUnderstandingResponse(
            captureID: captureID,
            result: ScreenUnderstandingResult(
                mode: mode,
                message: message,
                observations: observations,
                uncertainties: uncertainties,
                targetCandidateID: targetCandidateID
            ),
            metadata: ScreenUnderstandingMetadata(
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

#if DEBUG
private actor Challenge3ReplayStore {
    static let shared = Challenge3ReplayStore()

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("UniversalIO-Challenge3-Replays", isDirectory: true)
    private let maximumBundles = 20

    func record(
        requestID: String,
        request: Data?,
        image: Data,
        mediaType: String,
        response: Data?,
        error: String?
    ) {
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let bundle = root.appendingPathComponent(requestID, isDirectory: true)
            try FileManager.default.createDirectory(
                at: bundle,
                withIntermediateDirectories: true
            )
            if let request {
                try request.write(to: bundle.appendingPathComponent("request.json"), options: .atomic)
            }
            let imageName = mediaType == "image/jpeg" ? "image.jpg" : "image.png"
            try image.write(to: bundle.appendingPathComponent(imageName), options: .atomic)
            if let response {
                try response.write(to: bundle.appendingPathComponent("response.json"), options: .atomic)
            }
            if let error {
                try Data(error.utf8).write(
                    to: bundle.appendingPathComponent("error.txt"),
                    options: .atomic
                )
            }
            prune()
            NSLog("[Challenge3] replay bundle: %@", bundle.path)
        } catch {
            NSLog("[Challenge3] replay bundle write failed: %@", String(describing: error))
        }
    }

    private func prune() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let bundles = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let newestFirst = bundles.sorted {
            let lhs = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let rhs = try? $1.resourceValues(forKeys: keys).contentModificationDate
            return (lhs ?? .distantPast) > (rhs ?? .distantPast)
        }
        for expired in newestFirst.dropFirst(maximumBundles) {
            try? FileManager.default.removeItem(at: expired)
        }
    }
}
#endif
