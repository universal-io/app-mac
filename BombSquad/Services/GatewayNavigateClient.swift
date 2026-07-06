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

/// One event of a streaming navigation answer (SSE from the gateway).
enum NavigateStreamEvent {
    /// A plain-text increment of the answer as the model produces it.
    case delta(String)
    /// The full answer; always the last event of a successful stream.
    case result(text: String, harness: String?, modelID: String?)
}

/// Client for the screen navigator (POST /api/ai/navigate, always SSE).
/// The gateway owns prompts, model staging (fast first turn / main follow-up),
/// and harness selection — the client only sends the conversation plus hints
/// (docs/poc-ga-navigator.md §1-a). Gateway-only: the navigator has no BYOK
/// fallback.
struct GatewayNavigateClient {
    /// Navigation reads UI structure, not fine print: a screenshot downscaled
    /// to this long edge and recompressed is ~150-400KB instead of several MB,
    /// which is most of the "blazing fast" budget (upload + inference). Exact
    /// strings ride along as locally recognized OCR text instead.
    static let maxImageLongEdge: CGFloat = 1600
    private static let jpegQuality: CGFloat = 0.7

    private let api: GatewayAPI
    private let session: URLSession

    static func make() -> GatewayNavigateClient? {
        guard let api = GatewayAPI.make() else { return nil }
        return GatewayNavigateClient(api: api)
    }

    init(api: GatewayAPI, session: URLSession = .shared) {
        self.api = api
        self.session = session
    }

    /// Streams a navigation answer for the conversation so far. The last turn
    /// must be a user turn (the auto first turn is a user turn with an image
    /// and no text).
    func navigateStream(
        turns: [NavigateTurn],
        hints: SituationalContext?,
        language: OutputLanguage
    ) async throws -> AsyncThrowingStream<NavigateStreamEvent, Error> {
        var request = try await api.authorizedRequest("ai/navigate")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(turns: turns, hints: hints, language: language)
        )

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ProviderError.http(status: -1, body: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.http(status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 4096 { break }
            }
            throw GatewayAPI.error(status: http.statusCode, data: data)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var eventName = ""
                do {
                    // Same SSE framing as the review stream: one `data:` line
                    // per event, dispatched on the data line.
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            eventName = line.dropFirst("event:".count)
                                .trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        guard
                            let data = payload.data(using: .utf8),
                            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        switch eventName {
                        case "delta":
                            if let text = root["text"] as? String, !text.isEmpty {
                                continuation.yield(.delta(text))
                            }
                        case "result":
                            guard let result = root["result"] as? [String: Any],
                                  let text = result["text"] as? String else {
                                throw ProviderError.decoding("stream result had no payload")
                            }
                            let meta = root["meta"] as? [String: Any]
                            continuation.yield(.result(
                                text: text,
                                harness: result["harness"] as? String,
                                modelID: meta?["model_id"] as? String
                            ))
                        case "error":
                            throw GatewayAPI.error(status: 502, data: data)
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
        language: OutputLanguage
    ) -> [String: Any] {
        // Only the LATEST screenshot rides along. Sending the first one too
        // made the model mix up past and present ("Technology isn't open
        // yet" while looking at an old shot) — text history carries the
        // context; exactly one image means exactly one "now".
        let imageIndices = turns.indices.filter { turns[$0].imageBase64 != nil }
        let keptImageIndices = Set([imageIndices.last].compactMap { $0 })

        let messages: [[String: Any]] = turns.enumerated().map { index, turn in
            var payload: [String: Any] = ["role": turn.role.rawValue]
            if let text = turn.text, !text.isEmpty { payload["text"] = text }
            if keptImageIndices.contains(index), let image = turn.imageBase64 {
                payload["image_base64"] = image
                payload["media_type"] = turn.mediaType ?? "image/jpeg"
            }
            if let ocr = turn.ocrText, !ocr.isEmpty { payload["ocr_text"] = ocr }
            return payload
        }

        var input: [String: Any] = ["messages": messages]
        if let hints {
            var hintsPayload: [String: Any] = ["app_name": hints.appName]
            if let title = hints.windowTitle { hintsPayload["window_title"] = title }
            input["hints"] = hintsPayload
        }

        return [
            "request_id": UUID().uuidString,
            "operation": "navigate",
            "input": input,
            "preferences": ["output_language": language.rawValue],
            "client": GatewayAPI.clientPayload(),
        ]
    }
}
