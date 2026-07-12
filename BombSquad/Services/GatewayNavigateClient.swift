import AppKit
import Foundation

/// One turn of a navigator conversation, as sent to the gateway.
struct NavigateTurn {
    enum Role: String {
        case user
        case assistant
    }

    let role: Role
    var text: String?
    var imageBase64: String?
    var mediaType: String?
    var ocrText: String?
}

/// The session's step plan (docs/navigator-copilot-plan.md §3-a). Generated
/// once by the gateway planner, then owned by the client: it rides on every
/// request as `input.task`, and `currentStep` advances on the [[step:done]]
/// marker — the plan is data, not something the model re-derives per turn.
struct NavigatorTask: Equatable {
    struct Step: Equatable {
        let verbal: String
        /// Exact on-screen label, resolved to a position via OCR/AX.
        let target: String?
        /// Approval-driven text entry for input fields.
        let fill: String?
    }

    let goal: String
    let steps: [Step]
    var currentStep: Int

    var isFinished: Bool { currentStep >= steps.count }
}

/// One event of a streaming navigation answer (SSE from the gateway).
enum NavigateStreamEvent {
    /// A plain-text increment of the answer as the model produces it.
    case delta(String)
    /// The full answer; always the last event of a successful stream.
    /// `task` is a freshly planned step sequence awaiting the user's consent.
    case result(text: String, harness: String?, modelID: String?, task: NavigatorTask?)
}

/// Client for the screen navigator (POST /api/ai/navigate, always SSE).
/// The gateway owns prompts, model staging (fast first turn / main follow-up),
/// and harness selection — the client only sends the conversation plus hints
/// (docs/navigator-copilot-plan.md §9-a). Gateway-only: the navigator has no BYOK
/// fallback.
struct GatewayNavigateClient {
    /// Navigation reads UI structure, not fine print: a screenshot downscaled
    /// to this long edge and recompressed is ~150-400KB instead of several MB,
    /// which is most of the "blazing fast" budget (upload + inference). Exact
    /// strings ride along as locally recognized OCR text instead.
    static let maxImageLongEdge: CGFloat = 1600
    private static let jpegQuality: CGFloat = 0.7

    private let client: GatewayClient

    static func make() -> GatewayNavigateClient? {
        guard let client = GatewayClient.make() else { return nil }
        return GatewayNavigateClient(client: client)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    /// Streams a navigation answer for the conversation so far. The last turn
    /// must be a user turn (the auto first turn is a user turn with an image
    /// and no text). SSE framing/error mapping lives in `GatewayClient`.
    func navigateStream(
        turns: [NavigateTurn],
        hints: SituationalContext?,
        language: OutputLanguage,
        task: NavigatorTask? = nil
    ) async throws -> AsyncThrowingStream<NavigateStreamEvent, Error> {
        let events = try await client.postSSE(
            "ai/navigate",
            body: requestBody(turns: turns, hints: hints, language: language, task: task)
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        switch event.name {
                        case "delta":
                            if let text = event.json["text"] as? String, !text.isEmpty {
                                continuation.yield(.delta(text))
                            }
                        case "result":
                            guard let result = event.json["result"] as? [String: Any],
                                  let text = result["text"] as? String else {
                                throw ProviderError.decoding("stream result had no payload")
                            }
                            let meta = event.json["meta"] as? [String: Any]
                            continuation.yield(.result(
                                text: text,
                                harness: result["harness"] as? String,
                                modelID: meta?["model_id"] as? String,
                                task: Self.parseTask(result["task"])
                            ))
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decodes `result.task` from the result event; nil on any malformed
    /// shape (a broken plan must never enter the session state).
    private static func parseTask(_ value: Any?) -> NavigatorTask? {
        guard
            let dict = value as? [String: Any],
            let goal = dict["goal"] as? String, !goal.isEmpty,
            let rawSteps = dict["steps"] as? [[String: Any]], !rawSteps.isEmpty
        else { return nil }
        let steps = rawSteps.compactMap { raw -> NavigatorTask.Step? in
            guard let verbal = raw["verbal"] as? String, !verbal.isEmpty else { return nil }
            return NavigatorTask.Step(
                verbal: verbal,
                target: raw["target"] as? String,
                fill: raw["fill"] as? String
            )
        }
        guard steps.count == rawSteps.count else { return nil }
        return NavigatorTask(
            goal: goal,
            steps: steps,
            currentStep: max(0, (dict["current_step"] as? Int) ?? 0)
        )
    }

    // MARK: - Image preparation

    /// Downscales a screenshot to the navigator's wire size, burns in any
    /// user-drawn annotation rectangles ("about this part…"), and re-encodes
    /// as JPEG. Runs off the main thread (bitmap work on a full-screen Retina
    /// capture is tens of milliseconds).
    static func preparedImage(
        from url: URL,
        annotations: [ScreenshotAnnotation] = []
    ) async -> (base64: String, mediaType: String)? {
        await Task.detached(priority: .userInitiated) {
            preparedImageSync(from: url, annotations: annotations)
        }.value
    }

    private static func preparedImageSync(
        from url: URL,
        annotations: [ScreenshotAnnotation]
    ) -> (base64: String, mediaType: String)? {
        guard
            let data = try? Data(contentsOf: url),
            let source = NSBitmapImageRep(data: data),
            let cgImage = source.cgImage
        else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = min(1, maxImageLongEdge / max(width, height))
        let targetWidth = max(1, Int(width * scale))
        let targetHeight = max(1, Int(height * scale))

        var encoded = cgImage
        if scale < 1 || !annotations.isEmpty {
            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            drawAnnotations(annotations, in: context, width: targetWidth, height: targetHeight)
            guard let scaled = context.makeImage() else { return nil }
            encoded = scaled
        }

        let bitmap = NSBitmapImageRep(cgImage: encoded)
        guard let jpeg = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        ) else { return nil }
        return (jpeg.base64EncodedString(), "image/jpeg")
    }

    /// Strokes the user's annotation rectangles onto the wire image. The
    /// annotations are normalized with a top-left origin; CGContext draws
    /// bottom-left, hence the y flip.
    private static func drawAnnotations(
        _ annotations: [ScreenshotAnnotation],
        in context: CGContext,
        width: Int,
        height: Int
    ) {
        guard !annotations.isEmpty else { return }
        let w = CGFloat(width)
        let h = CGFloat(height)
        context.setLineWidth(max(3, w / 400))
        for annotation in annotations {
            let rect = CGRect(
                x: annotation.rect.minX * w,
                y: (1 - annotation.rect.maxY) * h,
                width: annotation.rect.width * w,
                height: annotation.rect.height * h
            )
            context.setStrokeColor(annotation.tint.nsColor.cgColor)
            context.stroke(rect)
        }
    }

    // MARK: - Request

    private func requestBody(
        turns: [NavigateTurn],
        hints: SituationalContext?,
        language: OutputLanguage,
        task: NavigatorTask?
    ) -> [String: Any] {
        // An active copilot already carries its complete plan in `task`.
        // Replaying the whole pre-copilot conversation makes old instructions
        // compete with the latest screen, so retain only the latest capture and
        // the final conversational beat. Plain navigator Q&A keeps full history.
        let effectiveTurns: [NavigateTurn]
        if task != nil {
            let latestCaptureIndex = turns.indices.last {
                turns[$0].imageBase64 != nil || turns[$0].ocrText != nil
            }
            let tailStart = max(0, turns.count - 2)
            var keptIndices = Set(tailStart..<turns.count)
            if let latestCaptureIndex {
                keptIndices.insert(latestCaptureIndex)
            }
            effectiveTurns = turns.indices
                .filter { keptIndices.contains($0) }
                .map { turns[$0] }
        } else {
            effectiveTurns = turns
        }

        // Only the LATEST screen-derived context rides along. Keeping one
        // image but every historical OCR dump still mixed past and present;
        // image and OCR now share the same single definition of "now". Treat
        // an OCR-only turn as a capture too, so a failed image encode cannot
        // accidentally resurrect the previous screenshot.
        let captureIndices = effectiveTurns.indices.filter {
            effectiveTurns[$0].imageBase64 != nil || effectiveTurns[$0].ocrText != nil
        }
        let latestCaptureIndex = captureIndices.last

        let messages: [[String: Any]] = effectiveTurns.enumerated().map { index, turn in
            var payload: [String: Any] = ["role": turn.role.rawValue]
            if let text = turn.text, !text.isEmpty {
                payload["text"] = text
            } else if index != latestCaptureIndex,
                      turn.imageBase64 != nil || turn.ocrText != nil {
                // Without a neutral text payload the gateway treats every
                // image-stripped historical capture as another fresh
                // re-capture instruction. Preserve the turn boundary while
                // making its non-current status explicit.
                payload["text"] = "（過去の画面取得。現在状態は最新の画像とOCRだけを参照する）"
            }
            if index == latestCaptureIndex, let image = turn.imageBase64 {
                payload["image_base64"] = image
                payload["media_type"] = turn.mediaType ?? "image/jpeg"
            }
            if index == latestCaptureIndex, let ocr = turn.ocrText, !ocr.isEmpty {
                payload["ocr_text"] = ocr
            }
            return payload
        }

        var input: [String: Any] = ["messages": messages]
        if let hints {
            var hintsPayload: [String: Any] = ["app_name": hints.appName]
            if let title = hints.windowTitle { hintsPayload["window_title"] = title }
            input["hints"] = hintsPayload
        }
        if let task {
            input["task"] = [
                "goal": task.goal,
                "steps": task.steps.map { step -> [String: Any] in
                    var payload: [String: Any] = ["verbal": step.verbal]
                    if let target = step.target { payload["target"] = target }
                    if let fill = step.fill { payload["fill"] = fill }
                    return payload
                },
                "current_step": task.currentStep,
            ] as [String: Any]
        }

        return GatewayClient.envelope(operation: "navigate", input: input, language: language)
    }
}
