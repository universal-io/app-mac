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

/// Where the panel's screenshot stands. Three states rather than an optional,
/// because "not yet" and "never" must look different to the user: an empty box
/// with no explanation is the symptom this project exists to remove.
enum ScreenshotImageState {
    case loading
    case ready(NSImage)
    case failed

    var image: NSImage? {
        if case .ready(let image) = self { return image }
        return nil
    }
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
    /// The screenshot as pixels, resolved by this session rather than by the
    /// view that draws it. `.failed` is a state the panel can explain; an image
    /// that silently never arrives is not (docs/reliability-hardening-plan.md D3).
    @Published private(set) var screenshotImage: ScreenshotImageState = .loading
    @Published private(set) var turns: [VisionDisplayTurn] = []
    /// The answer being written, shown while it is still arriving. Nil once the
    /// validated result has taken its place in `turns`, so the panel never holds
    /// both the draft and the finished version of the same answer.
    @Published private(set) var streamingMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var metadata: VisionMetadata?
    @Published private(set) var candidates: [VisionObservation.Candidate] = []
    @Published private(set) var candidatesReady = false
    @Published private(set) var candidateDiagnostics: VisionObservationCaptureService.Diagnostics?
    @Published private(set) var selection: VisionSelectionContext?
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
    /// When the user asked for the turn currently in flight — the double-tap
    /// for the opening turn, Enter for a question, the click for a copilot
    /// step. Every latency record in the turn is measured from here, so the
    /// trail reads as one ladder from one origin instead of several unrelated
    /// stopwatches (`SummonClock`).
    private var askClock: SummonClock
    private let candidateCaptureTask: Task<VisionObservationCaptureService.Snapshot, Never>
    /// Resolved separately from the candidate capture so the very first turn
    /// already carries the product identity; the candidate collection can take
    /// seconds on a cold browser tree and the opening observation does not wait
    /// for it.
    private var identityTask: Task<VisionObservationCaptureService.TargetIdentity?, Never>
    private var targetIdentity: VisionObservationCaptureService.TargetIdentity?
    private let onRequestPanelClose: () -> Void
    private let onRequestModeTransition: (AppMode, TransitionReason) -> Bool
    private var requestTask: Task<Void, Never>?
    private var copilotProgressTask: Task<Void, Never>?
    private var copilotClickMonitor: Any?
    private var copilotStepCount = 0
    private var hasStarted = false
    /// Whether a gateway request has actually left for this session. The
    /// coordinator supervises this: "the session object exists" and "the user's
    /// question was asked" are different facts, and on 2026-08-03 only the
    /// first was true.
    private(set) var hasIssuedRequest = false
    private var screenshotImageTask: Task<Void, Never>?
    private var requestCancellation: CancellationLedger?
    private var copilotCancellation: CancellationLedger?
    private var visionTurnDeadline: Task<Void, Never>?
    /// Whether this turn has already put something readable on screen. Guards
    /// the `vision.firstContent` measurement so it marks the first moment only,
    /// whether that came from a streamed increment or the finished result.
    private var turnHasVisibleContent = false

    init(
        attachment: ScreenshotAttachment,
        preferredTargetPID: pid_t? = nil,
        candidateCaptureTask: Task<VisionObservationCaptureService.Snapshot, Never>? = nil,
        identityTask: Task<VisionObservationCaptureService.TargetIdentity?, Never>? = nil,
        selection: VisionSelectionContext? = nil,
        client: GatewayVisionClient? = GatewayVisionClient.make(),
        // Handed in from the summon so the opening turn is measured from the
        // user's gesture, not from the moment this object happened to exist.
        askClock: SummonClock = SummonClock(),
        onRequestModeTransition: @escaping (AppMode, TransitionReason) -> Bool = { _, _ in true },
        onRequestPanelClose: @escaping () -> Void = {}
    ) {
        self.attachment = attachment
        self.preferredTargetPID = preferredTargetPID
        self.selection = selection
        self.askClock = askClock
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
        // Starts here, in the coordinator-owned initializer, so the decode
        // overlaps the transition and the panel setup instead of waiting for
        // the view to appear and then blocking the main thread on a 2560x1600
        // PNG.
        resolveScreenshotImage()
    }

    /// Reads the capture into memory. The only trigger is this session's own
    /// lifecycle: creation, and adopting a new capture during copilot.
    private func resolveScreenshotImage() {
        let expected = attachment.id
        let url = attachment.url
        screenshotImageTask?.cancel()
        screenshotImage = .loading
        screenshotImageTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            guard let self, !Task.isCancelled, self.attachment.id == expected else { return }
            self.screenshotImage = image.map { .ready($0) } ?? .failed
            if image == nil {
                Diagnostics.record("vision.screenshotUnreadable")
            }
        }
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
        Diagnostics.record("vision.start")
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

        // The origin moves to Enter: this turn's wait is the user's, and it has
        // nothing to do with how long ago the panel was summoned.
        askClock = SummonClock()
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
        guard onRequestModeTransition(.copilot, .copilotStarted) else {
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
        requestCancellation?.cause = .sessionTornDown
        requestTask?.cancel()
        requestTask = nil
        copilotCancellation?.cause = .sessionTornDown
        copilotProgressTask?.cancel()
        copilotProgressTask = nil
        screenshotImageTask?.cancel()
        screenshotImageTask = nil
        visionTurnDeadline?.cancel()
        visionTurnDeadline = nil
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
        let turnKind: VisionTurnKind = question == nil ? .first : .question
        requestCancellation?.cause = .supersededByNewerRequest
        requestTask?.cancel()
        OperationalNoticeCenter.shared.beginOperation()
        guard let client else {
            errorMessage = "画面読み取りサービスを利用できません。ログインと接続設定を確認してください。"
            return
        }

        isLoading = true
        errorMessage = nil
        streamingMessage = nil
        turnHasVisibleContent = false
        let expectedCaptureID = attachment.id
        let ledger = CancellationLedger()
        requestCancellation = ledger
        // A turn is more than its HTTP request: the AX candidate walk and the
        // product identity resolution are awaited on this side, and no
        // `timeoutInterval` covers them. This is the ceiling for the whole
        // thing, so every turn ends in an answer or in a sentence saying why
        // (docs/reliability-hardening-plan.md D5).
        visionTurnDeadline?.cancel()
        visionTurnDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(OperationDeadline.visionTurn))
            guard !Task.isCancelled else { return }
            self?.failTurnOnDeadline(ledger: ledger, turn: turnKind)
        }
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // Only the live request may clear the turn's state. A
                // superseded task resumes from its await *after* the newer
                // run() has already set up, so an unguarded cleanup here
                // stops the new turn's spinner and — now that text streams —
                // erases the answer being written for it.
                if self.requestCancellation === ledger {
                    self.isLoading = false
                    self.visionTurnDeadline?.cancel()
                    self.visionTurnDeadline = nil
                    // A half-written answer must not outlive the turn writing
                    // it: by here it is either superseded or meaningless.
                    self.streamingMessage = nil
                }
            }
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
                // Recorded BEFORE the call, not after. The 2026-08-03 stall had
                // no request trace and no failure trace, and only a record taken
                // at this point can tell "never asked" from "asked, never
                // answered" — the one distinction the log could not make.
                self.hasIssuedRequest = true
                Diagnostics.record("vision.request", details: [
                    ("turn", .code(turnKind)),
                    // Everything the user waited through before the request
                    // could even leave: the gesture, the capture, the panel,
                    // and the two waits below. Only this number is comparable
                    // to the provider's own timing.
                    ("sinceAsk", .ms(self.askClock.elapsedMs)),
                    ("candidatesWait", .ms(candidatesMs)),
                    ("identity", .ms(identityMs)),
                    ("candidates", .count(fixedCandidates.count)),
                ])
                let events = try await client.understandStream(
                    attachment: self.attachment,
                    question: question,
                    turns: priorTurns,
                    candidates: fixedCandidates,
                    candidateDiagnostics: fixedDiagnostics,
                    identity: identity,
                    selection: self.selection,
                    language: self.outputLanguage
                )
                var streamed: VisionResponse?
                for try await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .delta(let text):
                        self.appendStreamingText(text)
                    case .reset:
                        self.discardStreamedText(turn: turnKind)
                    case .result(let value):
                        streamed = value
                    }
                }
                guard let response = streamed else {
                    throw ProviderError.decoding("The Vision stream carried no result.")
                }
                Diagnostics.record("vision.turn", details: [
                    ("turn", .code(turnKind)),
                    ("sinceAsk", .ms(self.askClock.elapsedMs)),
                    ("gatewayRoundTrip", .ms(Self.elapsedMs(since: requestStarted))),
                    ("total", .ms(Self.elapsedMs(since: started))),
                ])
                try Task.checkCancellation()
                guard response.captureID == expectedCaptureID,
                      self.attachment.id == expectedCaptureID else {
                    throw ProviderError.decoding("The captured screen changed during the request.")
                }
                try self.apply(response, candidates: fixedCandidates)
            } catch is CancellationError {
                // A cancellation this session asked for needs no explanation:
                // a newer request will produce the outcome, and a torn-down
                // session has no panel to explain anything to. Any OTHER
                // cancellation dropped a completed request on the floor without
                // a word, which is the failure mode this project exists to
                // remove (docs/reliability-hardening-plan.md D6).
                guard ledger.cause == nil else { return }
                Diagnostics.record("vision.cancelledUnexplained", details: [
                    ("turn", .code(turnKind)),
                    ("sinceAsk", .ms(self.askClock.elapsedMs)),
                    ("total", .ms(Self.elapsedMs(since: started))),
                ])
                self.errorMessage = "画面の読み取りが中断されました。もう一度お試しください。"
            } catch {
                Diagnostics.record("vision.failed", details: [
                    ("turn", .code(turnKind)),
                    ("sinceAsk", .ms(self.askClock.elapsedMs)),
                    ("total", .ms(Self.elapsedMs(since: started))),
                    ("error", .code(DiagnosticErrorClass(error))),
                ])
#if DEBUG
                self.errorMessage =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
#else
                self.errorMessage = "画面の読み取りに失敗しました。少し待ってからもう一度お試しください。"
#endif
            }
        }
    }

    /// Second chance, driven by the coordinator's watchdog. Returns whether a
    /// restart was needed — `false` means the request had already left and
    /// nothing should be re-sent. Restarting cancels the stalled attempt first,
    /// so this cannot bill two requests.
    func restartIfNoRequestIssued() -> Bool {
        guard hasStarted, !hasIssuedRequest else { return false }
        Diagnostics.record("vision.restartedByWatchdog")
        run(question: nil, priorTurns: [])
        return true
    }

    /// Last stop for a session that never managed to ask anything. The user
    /// gets a sentence instead of a panel that waits forever.
    func reportStartFailure() {
        guard !hasIssuedRequest else { return }
        requestCancellation?.cause = .deadlineExceeded
        requestTask?.cancel()
        isLoading = false
        errorMessage = "画面の読み取りを開始できませんでした。もう一度お試しください。"
        Diagnostics.record("vision.startFailed")
    }

    /// The budget ran out. Ends the turn where the user can see it, rather
    /// than leaving a spinner that nothing will ever stop.
    private func failTurnOnDeadline(ledger: CancellationLedger, turn: VisionTurnKind) {
        guard isLoading, ledger.cause == nil else { return }
        ledger.cause = .deadlineExceeded
        requestTask?.cancel()
        isLoading = false
        errorMessage = "画面の読み取りが時間内に完了しませんでした。もう一度お試しください。"
        Diagnostics.record("vision.deadlineExceeded", details: [
            ("turn", .code(turn)),
            ("sinceAsk", .ms(askClock.elapsedMs)),
            ("budget", .ms(Int(OperationDeadline.visionTurn * 1000))),
        ])
    }

    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func appendStreamingText(_ text: String) {
        noteFirstContent(via: "stream", mode: nil)
        streamingMessage = (streamingMessage ?? "") + text
    }

    /// The gateway retracted what it had sent: the primary model died partway
    /// through and the secondary is answering from the beginning. Clearing this
    /// is the whole point — leaving it would splice two different answers
    /// together into one that neither model wrote.
    private func discardStreamedText(turn: VisionTurnKind) {
        Diagnostics.record("vision.streamReset", details: [
            ("turn", .code(turn)),
            ("sinceAsk", .ms(askClock.elapsedMs)),
        ])
        streamingMessage = nil
    }

    /// Marks when this turn first showed the user something readable, which is
    /// the number that says how fast the app feels. Recorded once per turn,
    /// naming which path got there so the streaming route can be told from the
    /// fallback that arrives all at once.
    private func noteFirstContent(via path: StaticString, mode: VisionResult.Mode?) {
        guard !turnHasVisibleContent else { return }
        turnHasVisibleContent = true
        var details: [(StaticString, DiagnosticValue)] = [
            ("sinceAsk", .ms(askClock.elapsedMs)),
            ("via", .literal(path)),
        ]
        if let mode { details.append(("mode", .code(mode))) }
        Diagnostics.record("vision.firstContent", details: details)
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
        // The user's click is the origin of a copilot step, and it is where
        // their wait starts — including the settle delay below, which is spent
        // on their behalf and therefore belongs in the number.
        askClock = SummonClock()
        OperationalNoticeCenter.shared.beginOperation()
        copilotCancellation?.cause = .supersededByNewerRequest
        copilotProgressTask?.cancel()
        isCopilotChecking = true
        copilotState = .waitingForChange
        copilotSawNoChange = false
        errorMessage = nil
        HighlightOverlayPresenter.shared.hide()
        let baseline = attachment
        let goal = copilotGoal
        let previousInstruction = latestInstruction
        let ledger = CancellationLedger()
        copilotCancellation = ledger
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
                // Copilot progress turns produced no operational record at all
                // until now: the 2026-08-03 trail had the AX walk and the
                // capture as DEBUG-only NSLog, so a shipped build reported
                // nothing for the slowest path in the product
                // (docs/guidance-accuracy-plan.md 1-k).
                Diagnostics.record("copilot.capture", details: [
                    ("sinceAsk", .ms(self.askClock.elapsedMs)),
                    ("attempts", .count(capture.attempts)),
                    ("changeObserved", .flag(capture.changeObserved)),
                    ("settled", .flag(capture.settled)),
                ])
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
                guard ledger.cause == nil else { return }
                Diagnostics.record("copilot.cancelledUnexplained")
                self.copilotState = .timedOut
                self.errorMessage = "画面の確認が中断されました。「再確認」を押してください。"
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
        let axStarted = Date()
        let snapshotTask = VisionObservationCaptureService.captureTask(
            preferredPID: preferredTargetPID,
            attachment: newAttachment
        )
        beginIdentityRefresh()
        let snapshot = await snapshotTask.value
        let axMs = Self.elapsedMs(since: axStarted)
        guard !Task.isCancelled, isCopilotActive else {
            try? FileManager.default.removeItem(at: newAttachment.url)
            return
        }
        let previousAttachment = attachment
        let previousCandidates = candidates
        let previousDiagnostics = candidateDiagnostics
        do {
            let requestStarted = Date()
            Diagnostics.record("copilot.request", details: [
                ("sinceAsk", .ms(askClock.elapsedMs)),
                ("ax", .ms(axMs)),
                ("candidates", .count(snapshot.axCandidates.count)),
            ])
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
            Diagnostics.record("copilot.turn", details: [
                ("sinceAsk", .ms(askClock.elapsedMs)),
                ("gatewayRoundTrip", .ms(Self.elapsedMs(since: requestStarted))),
            ])
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
            resolveScreenshotImage()
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
                resolveScreenshotImage()
                candidates = previousCandidates
                candidateDiagnostics = previousDiagnostics
            }
            try? FileManager.default.removeItem(at: newAttachment.url)
            copilotState = .timedOut
            Diagnostics.record("copilot.failed", details: [
                ("sinceAsk", .ms(askClock.elapsedMs)),
                ("error", .code(DiagnosticErrorClass(error))),
            ])
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
        // Normally the text is already on screen and this only confirms which
        // shape of answer it turned out to be. It still records first content
        // for the paths that never streamed — a `chat_completions` target, or a
        // fallback that arrived complete.
        noteFirstContent(via: "result", mode: response.result.mode)
        // The validated answer replaces the draft in the same breath, so the
        // panel is never showing both versions of one answer.
        streamingMessage = nil
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

/// Why an in-flight request was cancelled, recorded by whoever cancelled it.
///
/// A reference type so the answer travels with the request it belongs to: the
/// session can have a superseded request and a live one at the same moment, and
/// a single field on the session would give the wrong answer to one of them.
final class CancellationLedger {
    enum Cause {
        /// A newer request replaced this one; that request owns the outcome.
        case supersededByNewerRequest
        /// The user closed the panel. There is nobody left to tell.
        case sessionTornDown
        /// The turn ran past its budget. The watchdog that cancelled it owns
        /// the message, so the request path stays quiet.
        case deadlineExceeded
    }

    var cause: Cause?
}

/// Which turn a vision request belongs to. A named type rather than a string so
/// it can be recorded through `DiagnosticCode` (docs/reliability-hardening-plan.md D1).
enum VisionTurnKind: String, DiagnosticCode {
    case first
    case question
    case copilot

    var diagnosticCode: String { rawValue }
}
