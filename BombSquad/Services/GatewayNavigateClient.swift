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
    var observation: VisionObservation? = nil
}

/// Legacy v3 display/step plan (docs/navigator-copilot-plan.md §3-a).
/// During v4 shadow it still rides as `input.task` and advances on the
/// [[step:done]] marker, while the opaque signed Run is measured in parallel.
/// The rule-first Verifier replaces this client-owned progress in milestone D.
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

struct NavigatorCandidateGrounding {
    let captureID: UUID
    let candidateID: String
    let confidence: Double
    let method: String
}

/// Opaque Gateway-signed v4 state. The client transports this JSON unchanged;
/// it never edits Task, revision, step, tenant, or user fields locally.
struct NavigatorRunProposal: Equatable {
    fileprivate let json: Data
}

struct NavigatorRunSnapshot: Equatable {
    fileprivate let json: Data
}

/// Rule-first or escalated model result for one before/after Observation pair.
/// During shadow it is diagnostic only and cannot advance the v3 task.
struct NavigatorVerification: Equatable {
    enum Source: String {
        case rule
        case model
    }

    enum Status: String {
        case verified
        case notChanged = "not_changed"
        case ambiguous
        case blocked
        case complete
    }

    enum Reason: String {
        case allPostconditionsMet = "ALL_POSTCONDITIONS_MET"
        case noPostconditions = "NO_POSTCONDITIONS"
        case observationUnstable = "OBSERVATION_UNSTABLE"
        case captureScopeChanged = "CAPTURE_SCOPE_CHANGED"
        case targetDisabled = "TARGET_DISABLED"
        case noVisibleChange = "NO_VISIBLE_CHANGE"
        case insufficientOrConflictingEvidence = "INSUFFICIENT_OR_CONFLICTING_EVIDENCE"
        case modelPostconditionsSupported = "MODEL_POSTCONDITIONS_SUPPORTED"
        case modelNoVisibleChange = "MODEL_NO_VISIBLE_CHANGE"
        case modelTargetBlocked = "MODEL_TARGET_BLOCKED"
        case modelInsufficientEvidence = "MODEL_INSUFFICIENT_EVIDENCE"
    }

    let source: Source
    let status: Status
    let reason: Reason
    let evidenceCandidateIDs: [String]
    let confidence: Double?
}

/// One event of a streaming navigation answer (SSE from the gateway).
enum NavigateStreamEvent {
    /// A plain-text increment of the answer as the model produces it.
    case delta(String)
    /// The full answer; always the last event of a successful stream.
    /// `task` is a freshly planned step sequence awaiting the user's consent.
    case result(
        text: String,
        harness: String?,
        modelID: String?,
        task: NavigatorTask?,
        grounding: NavigatorCandidateGrounding?,
        runProposal: NavigatorRunProposal?,
        verification: NavigatorVerification?
    )
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
        task: NavigatorTask? = nil,
        runSnapshot: NavigatorRunSnapshot? = nil,
        previousObservation: VisionObservation? = nil
    ) async throws -> AsyncThrowingStream<NavigateStreamEvent, Error> {
        let events = try await client.postSSE(
            "ai/navigate",
            body: try requestBody(
                turns: turns,
                hints: hints,
                language: language,
                task: task,
                runSnapshot: runSnapshot,
                previousObservation: previousObservation
            )
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
                                task: Self.parseTask(result["task"]),
                                grounding: Self.parseGrounding(result["grounding"]),
                                runProposal: Self.parseRunProposal(result["run_proposal"]),
                                verification: try Self.parseVerification(result["verification"])
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

    private static func parseGrounding(_ value: Any?) -> NavigatorCandidateGrounding? {
        guard
            let dict = value as? [String: Any],
            let capture = dict["capture_id"] as? String,
            let captureID = UUID(uuidString: capture),
            let candidateID = dict["candidate_id"] as? String, !candidateID.isEmpty,
            let confidence = dict["confidence"] as? NSNumber,
            (0...1).contains(confidence.doubleValue),
            let method = dict["method"] as? String,
            method == "exact_unique" || method == "model"
        else { return nil }
        return NavigatorCandidateGrounding(
            captureID: captureID,
            candidateID: candidateID,
            confidence: confidence.doubleValue,
            method: method
        )
    }

    private static func parseVerification(_ value: Any?) throws -> NavigatorVerification? {
        guard let value, !(value is NSNull) else { return nil }
        guard
            let dict = value as? [String: Any],
            let rawSource = dict["source"] as? String,
            let source = NavigatorVerification.Source(rawValue: rawSource),
            let rawStatus = dict["status"] as? String,
            let status = NavigatorVerification.Status(rawValue: rawStatus),
            let rawReason = dict["reason"] as? String,
            let reason = NavigatorVerification.Reason(rawValue: rawReason),
            let evidence = dict["evidence_candidate_ids"] as? [String],
            evidence.allSatisfy({ !$0.isEmpty })
        else {
            throw ProviderError.decoding("ナビゲーション検証結果の形式が不正です")
        }
        let confidence: Double?
        if source == .model {
            guard
                let number = dict["confidence"] as? NSNumber,
                (0...1).contains(number.doubleValue)
            else {
                throw ProviderError.decoding("モデル検証結果に信頼度がありません")
            }
            confidence = number.doubleValue
        } else {
            confidence = nil
        }
        return NavigatorVerification(
            source: source,
            status: status,
            reason: reason,
            evidenceCandidateIDs: evidence,
            confidence: confidence
        )
    }

    /// Starts a v4 Run only after the user accepts the Planner proposal.
    /// This is shadow state until the rule-first Verifier becomes authoritative.
    func startRun(_ proposal: NavigatorRunProposal) async throws -> NavigatorRunSnapshot {
        let proposalObject = try Self.object(from: proposal.json, label: "run proposal")
        let data = try await client.postJSON("ai/navigate/run", body: [
            "request_id": UUID().uuidString,
            "action": "start",
            "proposal": proposalObject,
        ])
        return try Self.runSnapshot(from: data)
    }

    func syncRun(_ snapshot: NavigatorRunSnapshot) async throws -> NavigatorRunSnapshot {
        try await updateRun(action: "sync", snapshot: snapshot)
    }

    func cancelRun(_ snapshot: NavigatorRunSnapshot) async throws -> NavigatorRunSnapshot {
        try await updateRun(action: "cancel", snapshot: snapshot)
    }

    private func updateRun(
        action: String,
        snapshot: NavigatorRunSnapshot
    ) async throws -> NavigatorRunSnapshot {
        let snapshotObject = try Self.object(from: snapshot.json, label: "run snapshot")
        let data = try await client.postJSON("ai/navigate/run", body: [
            "request_id": UUID().uuidString,
            "action": action,
            "run_snapshot": snapshotObject,
        ])
        return try Self.runSnapshot(from: data)
    }

    private static func parseRunProposal(_ value: Any?) -> NavigatorRunProposal? {
        guard
            let value,
            JSONSerialization.isValidJSONObject(value),
            let dict = value as? [String: Any],
            dict["kind"] as? String == "navigate_run_proposal",
            dict["signature"] is String,
            let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        else { return nil }
        return NavigatorRunProposal(json: data)
    }

    private static func runSnapshot(from data: Data) throws -> NavigatorRunSnapshot {
        let root = try GatewayClient.rootObject(data)
        guard
            let result = root["result"] as? [String: Any],
            let snapshot = result["run_snapshot"] as? [String: Any],
            snapshot["signature"] is String,
            JSONSerialization.isValidJSONObject(snapshot),
            let encoded = try? JSONSerialization.data(
                withJSONObject: snapshot,
                options: [.sortedKeys]
            )
        else {
            throw ProviderError.decoding("run response had no signed snapshot")
        }
        return NavigatorRunSnapshot(json: encoded)
    }

    private static func object(from data: Data, label: String) throws -> [String: Any] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            JSONSerialization.isValidJSONObject(object)
        else {
            throw ProviderError.decoding("\(label) was not valid JSON")
        }
        return object
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
        task: NavigatorTask?,
        runSnapshot: NavigatorRunSnapshot?,
        previousObservation: VisionObservation?
    ) throws -> [String: Any] {
        // An active copilot already carries its complete goal and plan in
        // `task`. Its request contract is history-free: latest capture plus an
        // optional direct user utterance after that capture. Assistant history
        // and pre-copilot questions must never compete with current state.
        // Plain navigator Q&A keeps its conversation history for now.
        let effectiveTurns: [NavigateTurn]
        if task != nil {
            let latestCaptureIndex = turns.indices.last {
                turns[$0].imageBase64 != nil
                    || turns[$0].ocrText != nil
                    || turns[$0].observation != nil
            }
            var keptIndices = Set<Int>()
            if let latestCaptureIndex {
                keptIndices.insert(latestCaptureIndex)
            }
            let directUtteranceIndex = turns.indices.last { index in
                guard index > (latestCaptureIndex ?? -1) else { return false }
                let turn = turns[index]
                return turn.role == .user
                    && turn.imageBase64 == nil
                    && turn.ocrText == nil
                    && turn.observation == nil
                    && !(turn.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
            if let directUtteranceIndex {
                keptIndices.insert(directUtteranceIndex)
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
            effectiveTurns[$0].imageBase64 != nil
                || effectiveTurns[$0].ocrText != nil
                || effectiveTurns[$0].observation != nil
        }
        let latestCaptureIndex = captureIndices.last

        let messages: [[String: Any]] = effectiveTurns.enumerated().map { index, turn in
            var payload: [String: Any] = ["role": turn.role.rawValue]
            if let text = turn.text, !text.isEmpty {
                payload["text"] = text
            } else if index != latestCaptureIndex,
                      turn.imageBase64 != nil || turn.ocrText != nil || turn.observation != nil {
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
            if index == latestCaptureIndex, let observation = turn.observation {
                // Context exclusion applies to capture-time app/window identity
                // as well as legacy hints. OCR candidates remain part of the
                // explicitly captured screen and are still sent.
                payload["observation"] = observation.wirePayload(
                    includeEnvironment: hints != nil
                )
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
        switch (runSnapshot, previousObservation) {
        case let (.some(snapshot), .some(observation)):
            input["run_snapshot"] = try Self.object(
                from: snapshot.json,
                label: "run snapshot"
            )
            input["previous_observation"] = observation.wirePayload(
                includeEnvironment: hints != nil
            )
        case (nil, nil):
            break
        default:
            throw ProviderError.decoding(
                "ナビゲーション検証には署名済み状態と直前の画面情報の両方が必要です"
            )
        }

        return GatewayClient.envelope(operation: "navigate", input: input, language: language)
    }
}
