#if DEBUG
import AppKit
import Foundation

/// One explicit, AX-only sample. No auto-clicks, screenshots or polling loop.
@MainActor
final class JevCandidateExperiment: ObservableObject {
    struct Row: Identifiable {
        let id: String
        let label: String
        let parent: String?
        let probability: Double
    }
    struct Sample {
        let rows: [Row]
        let noneProbability: Double
        let choseNone: Bool
        let confidence: Double
        let candidateCount: Int
        let collectionNote: String?
        let axMs: Int
        let roundTripMs: Int
        let totalMs: Int
        let inputTokens: Int
        let providerMs: Int
        let observedAt: Date
    }
    struct AXProbe {
        let candidates: [VisionObservation.Candidate]
        let diagnostics: VisionObservationCaptureService.Diagnostics
        let observedAt: Date
    }
    @Published private(set) var sample: Sample?
    @Published private(set) var axProbe: AXProbe?
    @Published private(set) var axExportURL: URL?
    private var axGoal = ""
    private var axPreviousInstruction = ""
    private var axTurns: [VisionTurn] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var monitor: Any?
    private var activationObserver: NSObjectProtocol?

    func invalidate(_ reason: String? = nil) {
        generation += 1
        task?.cancel()
        task = nil
        sample = nil
        axProbe = nil
        isLoading = false
        message = reason
    }

    func startWatching(bubbleFrame: @escaping () -> CGRect?) {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) {
            [weak self] event in
            let location = NSEvent.mouseLocation
            let isKey = event.type == .keyDown
            Task { @MainActor [weak self] in
                if !isKey, bubbleFrame()?.contains(location) == true { return }
                self?.invalidate("操作があったため候補を破棄しました。「候補を更新」で再取得します。")
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidate("アプリが切り替わりました。「候補を更新」で再取得します。")
            }
        }
    }

    func stop() {
        invalidate()
        deleteAXExport()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func refresh(attachment: ScreenshotAttachment, preferredPID: pid_t?, goal: String,
                 previousInstruction: String, turns: [VisionTurn]) {
        invalidate()
        guard !goal.isEmpty, goal.count <= 4_000 else {
            message = "目的は1〜4,000文字で指定してください。"
            return
        }
        let token = generation
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == token { isLoading = false; task = nil }
            }
            let started = Date()
            // Uses only the existing capture's display geometry; reads no image bytes.
            let snapshot = await VisionObservationCaptureService.captureTask(
                preferredPID: preferredPID, attachment: attachment
            ).value
            guard !Task.isCancelled, generation == token else { return }
            let observedAt = Date()
            let axMs = Int(observedAt.timeIntervalSince(started) * 1_000)
            let candidates = snapshot.axCandidates.filter { !$0.states.contains("disabled") }
            guard !candidates.isEmpty else {
                message = "操作候補を取得できませんでした（\(snapshot.diagnostics.truncatedReason ?? "候補なし")）。AXの権限と対象画面を確認してください。"
                return
            }
            guard candidates.count <= 254 else {
                message = "候補が\(candidates.count)件あり、上限254件を超えています。対象の画面を絞ってください。候補を黙って切り捨てず、今回は送信しません。"
                return
            }
            do {
                let requestStarted = Date()
                let result = try await GatewayJevClient.suggest(
                    snapshotID: UUID(), goal: goal, previousInstruction: previousInstruction,
                    turns: turns, candidates: candidates, environment: snapshot.environment
                )
                guard !Task.isCancelled, generation == token else { return }
                var rows: [Row] = candidates.map { candidate in
                    Row(id: candidate.id, label: candidate.label, parent: candidate.parentLabel,
                        probability: result.probabilities[candidate.id] ?? 0)
                }
                rows.sort { left, right in
                    if left.probability == right.probability { return left.id < right.id }
                    return left.probability > right.probability
                }
                sample = Sample(rows: Array(rows.prefix(3)), noneProbability: result.probabilities["none"] ?? 0,
                                choseNone: result.choice == "none", confidence: result.confidence,
                                candidateCount: candidates.count, collectionNote: snapshot.diagnostics.truncatedReason,
                                axMs: axMs, roundTripMs: Int(Date().timeIntervalSince(requestStarted) * 1_000),
                                totalMs: Int(Date().timeIntervalSince(started) * 1_000),
                                inputTokens: result.inputTokens, providerMs: result.providerMs, observedAt: observedAt)
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                message = (error as? LocalizedError)?.errorDescription ?? "Jevの候補を取得できませんでした。"
            }
        }
    }

    /// Read-only local AX inspection. This deliberately stops before the Jev
    /// request so a browser tree can be verified without a network call.
    func refreshAXOnly(attachment: ScreenshotAttachment, preferredPID: pid_t?, goal: String,
                       previousInstruction: String, turns: [VisionTurn]) {
        invalidate()
        axGoal = goal
        axPreviousInstruction = previousInstruction
        axTurns = turns
        let token = generation
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == token { isLoading = false; task = nil }
            }
            let snapshot = await VisionObservationCaptureService.captureTask(
                preferredPID: preferredPID, attachment: attachment
            ).value
            guard !Task.isCancelled, generation == token else { return }
            axProbe = AXProbe(
                candidates: snapshot.axCandidates,
                diagnostics: snapshot.diagnostics,
                observedAt: Date()
            )
            if snapshot.axCandidates.isEmpty {
                let reason = snapshot.diagnostics.truncatedReason ?? "候補なし"
                message = "AX候補なし（\(reason)）。権限・対象画面・ブラウザの状態を確認してください。"
            }
        }
    }

    func exportAXProbe() {
        guard let probe = axProbe else { return }
        let candidates = probe.candidates.filter { !$0.states.contains("disabled") }
        guard candidates.count <= 254 else {
            message = "候補が\(candidates.count)件あり、上限254件を超えています。候補を絞ってから再取得してください。"
            return
        }
        let payload: [String: Any] = [
            "snapshot_id": UUID().uuidString,
            "goal": String(axGoal.prefix(4_000)),
            "previous_instruction": String(axPreviousInstruction.prefix(4_000)),
            "turns": axTurns.suffix(20).map { ["role": $0.role.rawValue, "text": String($0.text.prefix(4_000))] },
            "candidates": candidates.map { candidate -> [String: Any] in
                var payload: [String: Any] = [
                    "id": candidate.id,
                    "label": candidate.label,
                    "states": candidate.states,
                ]
                if let role = candidate.role { payload["role"] = role }
                if let parentLabel = candidate.parentLabel { payload["parent_label"] = parentLabel }
                return payload
            },
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        else { message = "AX結果を書き出せませんでした。"; return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("universal-io-ax-probe-\(UUID().uuidString).json")
        do {
            try? FileManager.default.removeItem(at: axExportURL ?? url)
            guard FileManager.default.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
            ) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url)
            axExportURL = url
            message = "AX結果を一時JSONへ保存しました。確認後に「一時JSONを削除」を押してください。"
        } catch {
            message = "AX結果を書き出せませんでした。"
        }
    }

    /// Copies the current in-memory AX snapshot only after an explicit click.
    /// This is a human-readable diagnostic; it is never sent or persisted.
    func copyAXProbe() {
        guard let probe = axProbe else { return }
        let appName = probe.diagnostics.targetAppName ?? "unknown"
        let reason = probe.diagnostics.truncatedReason ?? "complete"
        var lines = [
            "Universal I/O AX snapshot",
            "goal: \(axGoal)",
            "observed_at: \(ISO8601DateFormatter().string(from: probe.observedAt))",
            "target_app: \(appName)",
            "diagnostics: candidates=\(probe.candidates.count), elapsed_ms=\(probe.diagnostics.elapsedMs), visited_nodes=\(probe.diagnostics.visitedNodes), passes=\(probe.diagnostics.collectionPasses), web_area_present=\(probe.diagnostics.webAreaPresent), truncation=\(reason)",
            "candidates:",
        ]
        for candidate in probe.candidates {
            let rect = candidate.rect.map { "(\($0.minX), \($0.minY), \($0.width), \($0.height))" } ?? "—"
            lines.append("- id=\(candidate.id) role=\(candidate.role ?? "—") label=\(candidate.label) parent=\(candidate.parentLabel ?? "—") states=[\(candidate.states.joined(separator: ", "))] rect=\(rect)")
        }
        let text = lines.joined(separator: "\n")
        guard NSPasteboard.general.clearContents() > 0,
              NSPasteboard.general.setString(text, forType: .string) else {
            message = "AX結果をコピーできませんでした。"
            return
        }
        message = "AX結果をクリップボードへコピーしました。"
    }

    func deleteAXExport() {
        guard let url = axExportURL else { return }
        try? FileManager.default.removeItem(at: url)
        axExportURL = nil
        message = "一時JSONを削除しました。"
    }
}
#endif
