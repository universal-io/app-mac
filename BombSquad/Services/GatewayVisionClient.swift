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

/// One event of a streaming Vision turn (SSE from the gateway).
enum VisionStreamEvent {
    /// An increment of `result.message`, for reading only.
    case delta(String)
    /// Discard every delta so far. The primary model died partway through its
    /// answer and the secondary is starting a different one; the abandoned half
    /// must not stay on screen with a new answer appended to it.
    case reset
    /// The validated result. Always the last event of a successful stream, and
    /// the only thing the mode, the highlight target, and the uncertainties may
    /// be read from.
    case result(VisionResponse)
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
        let encoded = try await Self.encodedImage(for: attachment)
        // What actually went over the wire. Image tokens grow with area and are
        // most of the wait, so a change in this number explains a change in
        // latency that no other record would.
        Diagnostics.record("vision.image", details: [
            ("width", .count(encoded.width)),
            ("height", .count(encoded.height)),
            ("kb", .count(encoded.base64.count / 1024)),
        ])
        let input = Self.requestInput(
            attachment: attachment,
            imageBase64: encoded.base64,
            mediaType: encoded.mediaType,
            question: question,
            turns: turns,
            candidates: candidates,
            candidateDiagnostics: candidateDiagnostics,
            identity: identity,
            selection: selection,
            guidanceContext: guidanceContext
        )

        let body = GatewayClient.envelope(
            operation: "vision",
            input: input,
            language: language
        )
        let data = try await client.postJSON(
            "ai/vision",
            body: body,
            timeout: OperationDeadline.visionRequest
        )
        return try Self.decode(try GatewayClient.rootObject(data), expectedCaptureID: attachment.id)
    }

    /// The same turn, delivered as the model writes it.
    ///
    /// The answer is a JSON object, so the non-streaming call cannot show
    /// anything until generation ends — the user watches a spinner through the
    /// whole of it even though the sentence they need is finished early. Here
    /// the first increment typically arrives in a fraction of the total.
    func understandStream(
        attachment: ScreenshotAttachment,
        question: String?,
        turns: [VisionTurn],
        candidates: [VisionObservation.Candidate] = [],
        candidateDiagnostics: VisionObservationCaptureService.Diagnostics? = nil,
        identity: VisionObservationCaptureService.TargetIdentity? = nil,
        selection: VisionSelectionContext? = nil,
        guidanceContext: ScreenGuidanceContext? = nil,
        language: OutputLanguage
    ) async throws -> AsyncThrowingStream<VisionStreamEvent, Error> {
        let encoded = try await Self.encodedImage(for: attachment)
        // What actually went over the wire. Image tokens grow with area and are
        // most of the wait, so a change in this number explains a change in
        // latency that no other record would.
        Diagnostics.record("vision.image", details: [
            ("width", .count(encoded.width)),
            ("height", .count(encoded.height)),
            ("kb", .count(encoded.base64.count / 1024)),
        ])
        let input = Self.requestInput(
            attachment: attachment,
            imageBase64: encoded.base64,
            mediaType: encoded.mediaType,
            question: question,
            turns: turns,
            candidates: candidates,
            candidateDiagnostics: candidateDiagnostics,
            identity: identity,
            selection: selection,
            guidanceContext: guidanceContext
        )

        var body = GatewayClient.envelope(
            operation: "vision",
            input: input,
            language: language
        )
        body["stream"] = true
        let events = try await client.postSSE(
            "ai/vision",
            body: body,
            timeout: OperationDeadline.visionRequest
        )
        let expectedCaptureID = attachment.id

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var sawResult = false
                    for try await event in events {
                        switch event.name {
                        case "delta":
                            if let text = event.json["text"] as? String, !text.isEmpty {
                                continuation.yield(.delta(text))
                            }
                        case "reset":
                            continuation.yield(.reset)
                        case "result":
                            GatewayAPI.captureQuota(fromResponseRoot: event.json)
                            continuation.yield(.result(try Self.decode(
                                event.json,
                                expectedCaptureID: expectedCaptureID
                            )))
                            sawResult = true
                        case "error":
                            // Without this the stream would simply end, leaving
                            // the panel waiting on a turn the server already
                            // gave up on — the silent stall R11 exists to remove.
                            throw Self.streamError(event.json)
                        default:
                            break
                        }
                    }
                    guard sawResult else {
                        throw ProviderError.decoding(
                            "The Vision stream ended without a result."
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func streamError(_ json: [String: Any]) -> Error {
        let message = (json["error"] as? [String: Any])?["message"] as? String
        return ProviderError.gateway(
            message: message ?? "画面の読み取りに失敗しました。"
        )
    }

    /// Builds the one Vision Core input shape. Keeping this pure lets the C6
    /// contract test prove that Selection Extension changes only `selection`.
    static func requestInput(
        attachment: ScreenshotAttachment,
        imageBase64: String,
        mediaType: String,
        question: String?,
        turns: [VisionTurn],
        candidates: [VisionObservation.Candidate] = [],
        candidateDiagnostics: VisionObservationCaptureService.Diagnostics? = nil,
        identity: VisionObservationCaptureService.TargetIdentity? = nil,
        selection: VisionSelectionContext? = nil,
        guidanceContext: ScreenGuidanceContext? = nil
    ) -> [String: Any] {
        var input: [String: Any] = [
            "capture_id": attachment.id.uuidString,
            "image_base64": imageBase64,
            "media_type": mediaType,
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
        return input
    }

    /// The screen at one pixel per point.
    ///
    /// A Retina capture holds four times the pixels of what the user is looking
    /// at, and image tokens grow with area: the same Kinsta screen costs 7,756
    /// tokens at 3380x1892 and 2,052 at 1690x946. That prefill is most of the
    /// wait, and the extra pixels buy nothing measurable — at logical size the
    /// model read every line of an opened menu (11/11, three runs) and the small
    /// form values exactly as well as at full size, reproducing even full size's
    /// own single mistake. Below logical size it degrades, and it degrades
    /// silently: at 1/4 a port read 4141 instead of 41411, and at 1/4.5 「次に
    /// 適用する」came back as「次に進む」rather than as an admission that it was
    /// unreadable (docs/latency-plan.md 1-j).
    ///
    /// Normalized candidate rectangles are fractions of the capture, so nothing
    /// about the highlight geometry depends on how many pixels were sent.
    /// Runs off the calling actor, and must.
    ///
    /// `VisionSession` is `@MainActor`, so its request task inherits the main
    /// actor. Decoding a 3380x1892 PNG, re-encoding it, and base64-ing half a
    /// megabyte there would merely be slow — but `downscale` also installs a
    /// **global** `NSGraphicsContext.current`, and doing that on the main actor
    /// takes the drawing context out from under AppKit while SwiftUI may be
    /// mid-render. On 2026-08-05 a summon froze at "画面を見ています…" with
    /// NSHostingView reporting layout pass after layout pass skipped as
    /// reentrant. Reading a file and passing the bytes through, which is all this
    /// used to do, was cheap and touched no shared drawing state; this is neither.
    private static func encodedImage(
        for attachment: ScreenshotAttachment
    ) async throws -> (base64: String, mediaType: String, width: Int, height: Int) {
        let url = attachment.url
        let pixelWidth = attachment.pixelWidth
        let pixelHeight = attachment.pixelHeight
        let captureRect = attachment.captureRect
        return try await Task.detached(priority: .userInitiated) {
            try encodeForWire(
                url: url,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                captureRect: captureRect
            )
        }.value
    }

    private static func encodeForWire(
        url: URL,
        pixelWidth: Int?,
        pixelHeight: Int?,
        captureRect: CGRect?
    ) throws -> (base64: String, mediaType: String, width: Int, height: Int) {
        let source = try Data(contentsOf: url)
        let sourceType = url.pathExtension.lowercased() == "jpg"
            ? "image/jpeg"
            : "image/png"

        guard let bitmap = NSBitmapImageRep(data: source) else {
            // Unreadable as a bitmap: pass the bytes through rather than fail a
            // turn over an optimization.
            return (
                source.base64EncodedString(),
                sourceType,
                pixelWidth ?? 0,
                pixelHeight ?? 0
            )
        }

        let resized = logicalSize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            captureRect: captureRect
        ).flatMap { downscale(bitmap, to: $0) }
        let scaled = resized ?? bitmap
        let width = scaled.pixelsWide
        let height = scaled.pixelsHigh

        if resized == nil, source.count <= maxRawImageBytes {
            return (source.base64EncodedString(), sourceType, width, height)
        }
        if let png = scaled.representation(using: .png, properties: [:]),
           png.count <= maxRawImageBytes {
            return (png.base64EncodedString(), "image/png", width, height)
        }
        guard let jpeg = scaled.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.9]
        ) else {
            throw ProviderError.decoding("The captured image exceeds the Gateway limit.")
        }
        return (jpeg.base64EncodedString(), "image/jpeg", width, height)
    }

    /// The capture's size in points, when the capture is known to be denser than
    /// that. `captureRect` is in points and `pixelWidth` in pixels, so their
    /// ratio is the display's backing scale — no assumption about which Mac this
    /// is. Returns nil when there is nothing to gain or nothing to divide by.
    private static func logicalSize(
        pixelWidth: Int?,
        pixelHeight: Int?,
        captureRect: CGRect?
    ) -> NSSize? {
        guard let pixelWidth,
              let pixelHeight,
              let rect = captureRect,
              rect.width >= 1, rect.height >= 1,
              // A capture already at 1x, or one whose recorded size disagrees
              // with its rect, is left alone.
              Double(pixelWidth) > rect.width * 1.1 else { return nil }
        let scale = Double(pixelWidth) / rect.width
        return NSSize(
            width: (Double(pixelWidth) / scale).rounded(),
            height: (Double(pixelHeight) / scale).rounded()
        )
    }

    private static func downscale(_ bitmap: NSBitmapImageRep, to size: NSSize) -> NSBitmapImageRep? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        target.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Screen text survives a 2:1 reduction only with a real resampling
        // filter; nearest-neighbour turns 13pt glyphs into noise.
        context.imageInterpolation = .high
        bitmap.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return target
    }

    /// One contract check for both transports. The streamed `result` event and
    /// the non-streaming body are the same JSON by construction on the server,
    /// so validating them in two places could only let them drift.
    private static func decode(
        _ root: [String: Any],
        expectedCaptureID: UUID
    ) throws -> VisionResponse {
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
        // What the server says it spent, so the difference from the client's own
        // round trip is attributable instead of unexplained. On 2026-08-05 the
        // client measured 7.1s against a model call the server clocked at 2.8s,
        // and nothing accounted for the rest (docs/latency-plan.md 1-k).
        if let timing = meta["timing_ms"] as? [String: Any] {
            Diagnostics.record("vision.serverTiming", details: [
                ("body", .ms(timing["body"] as? Int ?? -1)),
                ("auth", .ms(timing["auth"] as? Int ?? -1)),
                ("quota", .ms(timing["quota"] as? Int ?? -1)),
                ("provider", .ms(timing["provider"] as? Int ?? -1)),
                ("total", .ms(timing["total"] as? Int ?? -1)),
            ])
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
