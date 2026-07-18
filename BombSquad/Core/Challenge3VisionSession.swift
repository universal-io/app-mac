import AppKit
import Foundation

enum Challenge3CopilotState: Equatable {
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

struct Challenge3VisionDisplayTurn: Identifiable, Equatable {
    let id = UUID()
    let role: ScreenUnderstandingTurn.Role
    let text: String
    let mode: ScreenUnderstandingResult.Mode?
    let uncertainties: [String]
}

/// Vision-first Challenge 3 state, intentionally independent from VisionSession.
@MainActor
final class Challenge3VisionSession: ObservableObject {
    @Published private(set) var attachment: ScreenshotAttachment
    @Published private(set) var turns: [Challenge3VisionDisplayTurn] = []
    @Published private(set) var isLoading = false
    @Published private(set) var metadata: ScreenUnderstandingMetadata?
    @Published private(set) var candidates: [VisionObservation.Candidate] = []
    @Published private(set) var candidatesReady = false
    @Published private(set) var candidateDiagnostics: VisionObservationCaptureService.Diagnostics?
    @Published private(set) var selectedCandidate: VisionObservation.Candidate?
    @Published private(set) var screenshotHighlight: CGRect?
    @Published private(set) var isCopilotActive = false
    @Published private(set) var copilotGoal: String?
    @Published private(set) var isCopilotChecking = false
    @Published private(set) var copilotState: Challenge3CopilotState = .idle
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

    private let client: GatewayScreenUnderstandingClient?
    private let outputLanguage: OutputLanguage
    private let preferredTargetPID: pid_t?
    private let candidateCaptureTask: Task<VisionObservationCaptureService.Snapshot, Never>
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
        client: GatewayScreenUnderstandingClient? = GatewayScreenUnderstandingClient.make(),
        onRequestModeTransition: @escaping (AppMode, String) -> Bool = { _, _ in true },
        onRequestPanelClose: @escaping () -> Void = {}
    ) {
        self.attachment = attachment
        self.preferredTargetPID = preferredTargetPID
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
        self.client = client
        self.outputLanguage = AppSettings.outputLanguage()
        self.onRequestModeTransition = onRequestModeTransition
        self.onRequestPanelClose = onRequestPanelClose
    }

    var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    var canStartCopilot: Bool {
        !isLoading
            && selectedCandidate?.rect != nil
            && turns.last(where: { $0.role == .assistant })?.mode == .guide
            && turns.last(where: { $0.role == .user }) != nil
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
        turns.append(Challenge3VisionDisplayTurn(
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
        guard onRequestModeTransition(.copilot, "challenge3CopilotStarted") else {
            // Roll back so a refused transition cannot leave the strip UI
            // stranded inside the centered panel with a live click monitor.
            isCopilotActive = false
            copilotGoal = nil
            focusedField = .navigator
            return
        }
        showLiveHighlight()
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
    }

    func requestCopilotProgressCheck() {
        // The user is asserting progress happened; skip the change watch and
        // go straight to a stability-timed capture.
        scheduleCopilotProgressCheck(after: 0, waitForChange: false)
    }

    private var wireTurns: [ScreenUnderstandingTurn] {
        turns.map { ScreenUnderstandingTurn(role: $0.role, text: $0.text) }
    }

    private func run(question: String?, priorTurns: [ScreenUnderstandingTurn]) {
        requestTask?.cancel()
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
            do {
                let fixedCandidates: [VisionObservation.Candidate]
                let fixedDiagnostics: VisionObservationCaptureService.Diagnostics?
                if question != nil {
                    if self.candidatesReady {
                        fixedCandidates = self.candidates
                        fixedDiagnostics = self.candidateDiagnostics
                    } else {
                        let snapshot = await self.candidateCaptureTask.value
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
                let response = try await client.understand(
                    attachment: self.attachment,
                    question: question,
                    turns: priorTurns,
                    candidates: fixedCandidates,
                    candidateDiagnostics: fixedDiagnostics,
                    language: self.outputLanguage
                )
                try Task.checkCancellation()
                guard response.captureID == expectedCaptureID,
                      self.attachment.id == expectedCaptureID else {
                    throw ProviderError.decoding("Challenge 3 capture changed during the request.")
                }
                try self.apply(response, candidates: fixedCandidates)
            } catch is CancellationError {
                return
            } catch {
#if DEBUG
                self.errorMessage =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
#else
                self.errorMessage = "画面の読み取りに失敗しました。少し待ってからもう一度お試しください。"
#endif
            }
        }
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
#if DEBUG
                NSLog(
                    "[Challenge3] progress capture adopted changeObserved=%d settled=%d",
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
                    "Challenge 3 progress turn returned observation mode."
                )
            }
            if let targetID = response.result.targetCandidateID {
                guard snapshot.axCandidates.contains(where: {
                    $0.id == targetID && $0.rect != nil
                }) else {
                    throw ProviderError.decoding(
                        "Challenge 3 progress selected an unusable candidate."
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
        _ response: ScreenUnderstandingResponse,
        candidates fixedCandidates: [VisionObservation.Candidate]
    ) throws {
        metadata = response.metadata
        if let targetID = response.result.targetCandidateID {
            guard let candidate = fixedCandidates.first(where: { $0.id == targetID }),
                  let rect = candidate.rect else {
                throw ProviderError.decoding(
                    "Challenge 3 selected a candidate without a usable capture rectangle."
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
        turns.append(Challenge3VisionDisplayTurn(
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
    }
}
