import AppKit
import Foundation

enum CopilotState: Equatable {
    case idle
    case waitingForChange
    case evaluating
    case timedOut
    case complete
    case clarification
    /// Deterministic stop valve: the guide loop has no model-independent
    /// halt condition, so a runaway back-and-forth would keep billing until
    /// the user quits. Terminal like `.complete`.
    case stepLimit
}

struct VisionDisplayTurn: Identifiable, Equatable {
    let id = UUID()
    let role: VisionTurn.Role
    let text: String
    let mode: VisionResult.Mode?
    let uncertainties: [String]
}

@MainActor
final class VisionSession: ObservableObject {
    @Published private(set) var attachment: ScreenshotAttachment
    @Published private(set) var turns: [VisionDisplayTurn] = []
    @Published private(set) var isLoading = false
    @Published private(set) var metadata: VisionMetadata?
    @Published private(set) var candidates: [VisionObservation.Candidate] = []
    @Published private(set) var candidatesReady = false
    @Published private(set) var candidateDiagnostics: VisionObservationCaptureService.Diagnostics?
    @Published private(set) var focusTarget: VisionFocusTarget?
    /// Display name of the skill the gateway applied to the latest turn. Always
    /// shown: knowledge the user cannot see is knowledge they cannot correct.
    @Published private(set) var activeSkillName: String?
    @Published private(set) var selectedCandidate: VisionObservation.Candidate?
    @Published private(set) var screenshotHighlight: CGRect?
    @Published private(set) var isCopilotActive = false
    @Published private(set) var copilotGoal: String?
    @Published private(set) var isCopilotChecking = false
    @Published private(set) var copilotState: CopilotState = .idle
    /// True while the latest progress turn was evaluated from a capture in
    /// which no screen change was visible despite the user's action — shown
    /// as an honest note next to the (likely repeated) guidance.
    @Published private(set) var copilotSawNoChange = false
    @Published var input = ""
    @Published var errorMessage: String?
    @Published var focusedField: FocusField? = .navigator
    @Published var isRecording = false
    @Published var isTranscribing = false

    private static let maxGuideSteps = 15

    private let client: GatewayVisionClient?
    private let outputLanguage: OutputLanguage
    private let preferredTargetPID: pid_t?
    private let visualSelectionHint: Bool
    private let candidateCaptureTask: Task<VisionObservationCaptureService.Snapshot, Never>
    /// Resolved separately from the candidate capture so the very first turn
    /// already carries the product identity; the candidate collection can take
    /// seconds on a cold browser tree and the opening observation does not wait
    /// for it.
    private var identityTask: Task<VisionObservationCaptureService.TargetIdentity?, Never>
    private var targetIdentity: VisionObservationCaptureService.TargetIdentity?
    private let onRequestPanelClose: () -> Void
    private let onRequestModeTransition: (AppMode, String) -> Bool
    private var requestTask: Task<Void, Never>?
    private var copilotProgressTask: Task<Void, Never>?
    private var copilotClickMonitor: Any?
    private var copilotStepCount = 0
    private var hasStarted = false

    init(
        attachment: ScreenshotAttachment,
        preferredTargetPID: pid_t? = nil,
        candidateCaptureTask: Task<VisionObservationCaptureService.Snapshot, Never>? = nil,
        identityTask: Task<VisionObservationCaptureService.TargetIdentity?, Never>? = nil,
        focusTarget: VisionFocusTarget? = nil,
        visualSelectionHint: Bool = false,
        client: GatewayVisionClient? = GatewayVisionClient.make(),
        onRequestModeTransition: @escaping (AppMode, String) -> Bool = { _, _ in true },
        onRequestPanelClose: @escaping () -> Void = {}
    ) {
        self.attachment = attachment
        self.preferredTargetPID = preferredTargetPID
        self.focusTarget = focusTarget
        self.visualSelectionHint = visualSelectionHint && focusTarget == nil
        self.candidateCaptureTask = candidateCaptureTask ?? Task {
            VisionObservationCaptureService.Snapshot(
                environment: nil,
                axCandidates: [],
                diagnostics: VisionObservationCaptureService.Diagnostics(
                    elapsedMs: 0,
                    visitedNodes: 0,
                    candidateCount: 0,
                    truncatedReason: "not_configured"
                )
            )
        }
        // Normally handed in from the summon, where it started in parallel with
        // the screenshot. Resolving it here instead means starting after the
        // capture finished, which is exactly the wait we are avoiding.
        self.identityTask = identityTask ?? VisionObservationCaptureService.identityTask(
            preferredPID: preferredTargetPID
        )
        self.client = client
        self.outputLanguage = AppSettings.outputLanguage()
        self.onRequestModeTransition = onRequestModeTransition
        self.onRequestPanelClose = onRequestPanelClose
    }

    var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    var canStartCopilot: Bool {
        guard !isLoading,
              let assistant = turns.last(where: { $0.role == .assistant }),
              let question = turns.last(where: { $0.role == .user })?.text else {
            return false
        }
        return assistant.mode == .guide || Self.isActionSeekingQuestion(question)
    }

    private static func isActionSeekingQuestion(_ question: String) -> Bool {
        let normalized = question.lowercased()
        let markers = [
            "どこ", "どうやって", "方法", "行き方", "開く", "開け", "取得",
            "作成", "設定", "変更", "クリック", "押す", "操作", "見つけ",
            "where", "how do", "how can", "open", "go to", "find", "get ",
            "create", "set up", "configure", "change", "click", "press",
        ]
        return markers.contains { normalized.contains($0) }
    }

    var latestInstruction: String {
        turns.last(where: { $0.role == .assistant })?.text ?? "案内を準備しています…"
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        let expectedCaptureID = attachment.id
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.candidateCaptureTask.value
            guard !Task.isCancelled, self.attachment.id == expectedCaptureID else { return }
            self.candidates = snapshot.axCandidates
            self.candidateDiagnostics = snapshot.diagnostics
            self.candidatesReady = true
        }
        run(question: nil, priorTurns: [])
    }

    func sendQuestion() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoading else { return }

        let priorTurns = wireTurns
        input = ""
        errorMessage = nil
        turns.append(VisionDisplayTurn(
            role: .user,
            text: question,
            mode: nil,
            uncertainties: []
        ))
        run(question: question, priorTurns: priorTurns)
    }

    func appendTranscription(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        input += input.isEmpty || input.last?.isWhitespace == true ? piece : " \(piece)"
        focusedField = .navigator
    }

    func requestPanelClose() {
        onRequestPanelClose()
    }

    func startCopilot() {
        guard canStartCopilot,
              let goal = turns.last(where: { $0.role == .user })?.text else { return }
        copilotGoal = goal
        copilotStepCount = 0
        isCopilotActive = true
        copilotState = .idle
        copilotSawNoChange = false
        focusedField = nil
        guard onRequestModeTransition(.copilot, "copilotStarted") else {
            // Roll back so a refused transition cannot leave the strip UI
            // stranded inside the centered panel with a live click monitor.
            isCopilotActive = false
            copilotGoal = nil
            focusedField = .navigator
            return
        }
        if selectedCandidate?.rect != nil {
            showLiveHighlight()
        } else {
            // A useful guide answer can exist even when Chrome/Electron did
            // not expose a matching AX rectangle. Copilot remains usable as
            // text guidance; only the optional highlight is omitted.
            activateTargetApp()
        }
        installCopilotClickMonitor()
    }

    /// Ending the copilot ends the session: the goal was either reached or
    /// abandoned, so the strip just disappears — no return to the big panel.
    func stopCopilot() {
        guard isCopilotActive else { return }
        isCopilotActive = false
        copilotProgressTask?.cancel()
        copilotProgressTask = nil
        isCopilotChecking = false
        removeCopilotClickMonitor()
        HighlightOverlayPresenter.shared.hide()
        onRequestPanelClose()
    }

    func tearDown() {
        requestTask?.cancel()
        requestTask = nil
        copilotProgressTask?.cancel()
        copilotProgressTask = nil
        removeCopilotClickMonitor()
        HighlightOverlayPresenter.shared.hide()
        try? FileManager.default.removeItem(at: attachment.url)
    }

    func requestCopilotProgressCheck() {
        // The user is asserting progress happened; skip the change watch and
        // go straight to a stability-timed capture.
        scheduleCopilotProgressCheck(after: 0, waitForChange: false)
    }

    private var wireTurns: [VisionTurn] {
        turns.map { VisionTurn(role: $0.role, text: $0.text) }
    }

    /// A resolved identity is reused, except when it came back without a host.
    /// A browser that had not yet built its web AX tree looks exactly like a
    /// native app, so caching that answer would hide a web product for the rest
    /// of the session. The concurrent candidate passes warm that tree within a
    /// second, so retrying on the next turn is what recovers it.
    private func resolvedIdentity() async -> VisionObservationCaptureService.TargetIdentity? {
        if let targetIdentity, targetIdentity.host != nil { return targetIdentity }
        if targetIdentity != nil {
            identityTask = VisionObservationCaptureService.identityTask(
                preferredPID: preferredTargetPID
            )
        }
        let resolved = await identityTask.value
        targetIdentity = resolved
        return resolved
    }

    /// Re-resolve for a copilot progress turn: guidance routinely walks the user
    /// from one product into another, and the skill has to follow them. Started
    /// rather than awaited, so it runs alongside the progress capture.
    private func beginIdentityRefresh() {
        identityTask = VisionObservationCaptureService.identityTask(
            preferredPID: preferredTargetPID
        )
        targetIdentity = nil
    }

    private func run(question: String?, priorTurns: [VisionTurn]) {
        requestTask?.cancel()
        OperationalNoticeCenter.shared.beginOperation()
        guard let client else {
            errorMessage = "画面読み取りサービスを利用できません。ログインと接続設定を確認してください。"
            return
        }

        isLoading = true
        errorMessage = nil
        let expectedCaptureID = attachment.id
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }
            // Phase timing: the gateway records only its own model call, so the
            // waits on this side — the AX candidate walk and the product
            // identity resolution, both of which run extra passes on Chromium —
            // were invisible. A user reporting "vision is slow" could not be
            // answered from server numbers alone.
            let started = Date()
            var candidatesMs = 0
            var identityMs = 0
            do {
                let fixedCandidates: [VisionObservation.Candidate]
                let fixedDiagnostics: VisionObservationCaptureService.Diagnostics?
                if question != nil {
                    if self.candidatesReady {
                        fixedCandidates = self.candidates
                        fixedDiagnostics = self.candidateDiagnostics
                    } else {
                        let waitStarted = Date()
                        let snapshot = await self.candidateCaptureTask.value
                        candidatesMs = Self.elapsedMs(since: waitStarted)
                        try Task.checkCancellation()
                        fixedCandidates = snapshot.axCandidates
                        fixedDiagnostics = snapshot.diagnostics
                        self.candidates = fixedCandidates
                        self.candidateDiagnostics = snapshot.diagnostics
                        self.candidatesReady = true
                    }
                } else {
                    fixedCandidates = []
                    fixedDiagnostics = nil
                }
                let identityStarted = Date()
                let identity = await self.resolvedIdentity()
                identityMs = Self.elapsedMs(since: identityStarted)
                let requestStarted = Date()
                let response = try await client.understand(
                    attachment: self.attachment,
                    question: question,
                    turns: priorTurns,
                    candidates: fixedCandidates,
                    candidateDiagnostics: fixedDiagnostics,
                    identity: identity,
                    focusTarget: self.focusTarget,
                    visualSelectionHint: self.visualSelectionHint,
                    language: self.outputLanguage
                )
                VisionTrace.log(
                    "turn=\(question == nil ? "first" : "question") "
                    + "candidatesWait=\(candidatesMs)ms identity=\(identityMs)ms "
                    + "gatewayRoundTrip=\(Self.elapsedMs(since: requestStarted))ms "
                    + "total=\(Self.elapsedMs(since: started))ms "
                    + "candidates=\(fixedCandidates.count)"
                )
                try Task.checkCancellation()
                guard response.captureID == expectedCaptureID,
                      self.attachment.id == expectedCaptureID else {
                    throw ProviderError.decoding("The captured screen changed during the request.")
                }
                try self.apply(response, candidates: fixedCandidates)
            } catch is CancellationError {
                return
            } catch {
                VisionTrace.log(
                    "failed after candidatesWait=\(candidatesMs)ms identity=\(identityMs)ms "
                    + "total=\(Self.elapsedMs(since: started))ms"
                )
#if DEBUG
                self.errorMessage =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
#else
                self.errorMessage = "画面の読み取りに失敗しました。少し待ってからもう一度お試しください。"
#endif
            }
        }
    }

    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func installCopilotClickMonitor() {
        guard copilotClickMonitor == nil else { return }
        copilotClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleCopilotProgressCheck(after: 700_000_000, waitForChange: true)
            }
        }
    }

    private func removeCopilotClickMonitor() {
        if let copilotClickMonitor {
            NSEvent.removeMonitor(copilotClickMonitor)
            self.copilotClickMonitor = nil
        }
    }

    private func scheduleCopilotProgressCheck(after delay: UInt64, waitForChange: Bool) {
        guard isCopilotActive, !isCopilotChecking,
              copilotState != .complete, copilotState != .stepLimit else { return }
        OperationalNoticeCenter.shared.beginOperation()
        copilotProgressTask?.cancel()
        isCopilotChecking = true
        copilotState = .waitingForChange
        copilotSawNoChange = false
        errorMessage = nil
        HighlightOverlayPresenter.shared.hide()
        let baseline = attachment
        let goal = copilotGoal
        let previousInstruction = latestInstruction
        copilotProgressTask = Task { [weak self] in
            guard let self, let goal else { return }
            defer {
                self.isCopilotChecking = false
                self.copilotProgressTask = nil
            }
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                let capture = try await StableScreenCaptureService.capture(
                    after: baseline,
                    waitForChange: waitForChange
                )
                try Task.checkCancellation()
                guard self.isCopilotActive else {
                    try? FileManager.default.removeItem(at: capture.attachment.url)
                    return
                }
                // Confirm the exact adopted frame after capture, without
                // delaying AX collection or the Gateway request.
                CopilotCaptureCuePresenter.shared.flash(for: capture.attachment)
#if DEBUG
                NSLog(
                    "Vision progress capture adopted changeObserved=%d settled=%d",
                    capture.changeObserved ? 1 : 0, capture.settled ? 1 : 0
                )
#endif
                self.copilotSawNoChange = !capture.changeObserved && waitForChange
                await self.evaluateCopilotProgress(
                    attachment: capture.attachment,
                    goal: goal,
                    previousInstruction: previousInstruction
                )
            } catch is CancellationError {
                return
            } catch {
                self.copilotState = .timedOut
#if DEBUG
                self.errorMessage =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
#else
                self.errorMessage = "画面を確認できませんでした。「再確認」を押してください。"
#endif
            }
        }
    }

    private func evaluateCopilotProgress(
        attachment newAttachment: ScreenshotAttachment,
        goal: String,
        previousInstruction: String
    ) async {
        guard let client else { return }
        copilotState = .evaluating
        let snapshotTask = VisionObservationCaptureService.captureTask(
            preferredPID: preferredTargetPID,
            attachment: newAttachment
        )
        beginIdentityRefresh()
        let snapshot = await snapshotTask.value
        guard !Task.isCancelled, isCopilotActive else {
            try? FileManager.default.removeItem(at: newAttachment.url)
            return
        }
        let previousAttachment = attachment
        let previousCandidates = candidates
        let previousDiagnostics = candidateDiagnostics
        do {
            let response = try await client.understand(
                attachment: newAttachment,
                question: nil,
                turns: [],
                candidates: snapshot.axCandidates,
                candidateDiagnostics: snapshot.diagnostics,
                identity: await resolvedIdentity(),
                guidanceContext: ScreenGuidanceContext(
                    goal: goal,
                    previousInstruction: previousInstruction
                ),
                language: outputLanguage
            )
            try Task.checkCancellation()
            guard isCopilotActive, response.captureID == newAttachment.id else {
                try? FileManager.default.removeItem(at: newAttachment.url)
                return
            }
            guard response.result.mode != .observation else {
                throw ProviderError.decoding(
                    "Vision progress turn returned observation mode."
                )
            }
            if let targetID = response.result.targetCandidateID {
                guard snapshot.axCandidates.contains(where: {
                    $0.id == targetID && $0.rect != nil
                }) else {
                    throw ProviderError.decoding(
                        "Vision progress selected an unusable candidate."
                    )
                }
            }
            attachment = newAttachment
            candidates = snapshot.axCandidates
            candidateDiagnostics = snapshot.diagnostics
            candidatesReady = true
            try apply(response, candidates: snapshot.axCandidates)
            if previousAttachment.id != newAttachment.id {
                try? FileManager.default.removeItem(at: previousAttachment.url)
            }
            switch response.result.mode {
            case .answer:
                copilotState = .complete
                removeCopilotClickMonitor()
                HighlightOverlayPresenter.shared.hide()
            case .guide:
                copilotStepCount += 1
                if copilotStepCount >= Self.maxGuideSteps {
                    copilotState = .stepLimit
                    removeCopilotClickMonitor()
                    HighlightOverlayPresenter.shared.hide()
                } else {
                    copilotState = .idle
                    installCopilotClickMonitor()
                }
            case .clarification:
                // Clarification is now also a decision point ("this needs
                // sign-in — continue?"), not only a dead end. Keep watching
                // for clicks so that if the user decides to proceed by
                // acting, the copilot follows; apply() already set/cleared
                // the highlight based on whether a target was returned.
                copilotState = .clarification
                installCopilotClickMonitor()
            case .observation:
                break
            }
        } catch {
            if attachment.id == newAttachment.id {
                attachment = previousAttachment
                candidates = previousCandidates
                candidateDiagnostics = previousDiagnostics
            }
            try? FileManager.default.removeItem(at: newAttachment.url)
            copilotState = .timedOut
#if DEBUG
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
#else
            errorMessage = "次の案内を確認できませんでした。「再確認」を押してください。"
#endif
        }
    }

    private func apply(
        _ response: VisionResponse,
        candidates fixedCandidates: [VisionObservation.Candidate]
    ) throws {
        metadata = response.metadata
        activeSkillName = response.skillName
        if let targetID = response.result.targetCandidateID {
            guard let candidate = fixedCandidates.first(where: { $0.id == targetID }),
                  let rect = candidate.rect else {
                throw ProviderError.decoding(
                    "Vision selected a candidate without a usable capture rectangle."
                )
            }
            selectedCandidate = candidate
            screenshotHighlight = rect
            if isCopilotActive { showLiveHighlight() }
        } else {
            selectedCandidate = nil
            screenshotHighlight = nil
            if isCopilotActive { HighlightOverlayPresenter.shared.hide() }
        }
        turns.append(VisionDisplayTurn(
            role: .assistant,
            text: response.result.message,
            mode: response.result.mode,
            uncertainties: response.result.uncertainties
        ))
    }

    private func showLiveHighlight() {
        guard let rect = selectedCandidate?.rect,
              let captureRect = attachment.captureRect else { return }
        let globalRect = CGRect(
            x: captureRect.minX + rect.minX * captureRect.width,
            y: captureRect.minY + rect.minY * captureRect.height,
            width: rect.width * captureRect.width,
            height: rect.height * captureRect.height
        )
        HighlightOverlayPresenter.shared.show(around: globalRect, duration: nil, padding: 6)
        // Whenever we point at a control to click, the target app must be
        // frontmost — otherwise the user's first click is spent activating
        // its window (macOS click-to-focus) instead of pressing the control,
        // yet our global monitor still fires and clears the ring. Handing
        // focus back makes the very first click act. The strip floats above
        // and does not close on resign-active, so nothing is lost.
        activateTargetApp()
    }

    /// Returns frontmost status to the app being navigated. No-op when it is
    /// already active (e.g. mid-task, after the user clicked in it).
    private func activateTargetApp() {
        guard let pid = preferredTargetPID,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isActive else { return }
        app.activate()
    }
}

/// Debug-only phase timing for vision. The gateway's `latency_ms` covers its
/// model call and nothing else, so everything this side spends — waiting for the
/// AX candidate walk, resolving which product is on screen, the round trip
/// itself — was unmeasured. "Vision feels slow" needs these numbers to be
/// answerable; without them the only available answer is a guess.
enum VisionTrace {
    static func log(_ message: String) {
        #if DEBUG
        NSLog("[Vision] %@", message)
        #endif
    }
}
