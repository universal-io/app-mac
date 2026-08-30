import AppKit
import SwiftUI

/// Input events the coordinator understands. AppDelegate (or, later, the
/// monitors directly) translates raw gestures into these; nothing else in
/// the core knows about NSEvent.
enum AppEvent: CustomStringConvertible {
    /// Right Shift single tap: toggle editor focus (mode-dependent).
    case singleTap
    /// Right Shift double tap: summon / review / vision / close.
    case doubleTap
    /// Right Shift held: hold-to-talk dictation.
    case longPressBegan
    case longPressEnded
    /// Explicit panel command from the menu-bar item.
    case menuPanelToggle
    /// Explicit camera button in the compose surface.
    case screenshotCaptureRequested
    /// Esc or an in-window close request.
    case closeRequested
    /// The app lost active status (another app's window took focus).
    case appResignedActive

    var description: String {
        switch self {
        case .singleTap: return "singleTap"
        case .doubleTap: return "doubleTap"
        case .longPressBegan: return "longPressBegan"
        case .longPressEnded: return "longPressEnded"
        case .menuPanelToggle: return "menuPanelToggle"
        case .screenshotCaptureRequested: return "screenshotCaptureRequested"
        case .closeRequested: return "closeRequested"
        case .appResignedActive: return "appResignedActive"
        }
    }
}

/// The rebuilt center: translates events into `AppMode` transitions and
/// drives the `PanelController`. This is the ONLY place that decides what a
/// gesture means in a given mode.
///
/// Phase 1 introduced the machinery; Phase 3 moved Compose, Vision,
/// Navigator, and Copilot here; Phase 4 made it the live path.
@MainActor
final class SessionCoordinator {
    private enum CaptureCompletion {
        case attachment(ScreenshotAttachment)
        case cancelled
        case failed(String)
    }

    let stateMachine = AppStateMachine()
    private let panelController = PanelController()
    private let recorder = AudioRecorder()
    private let screenshotCapture = ScreenshotCaptureService()
    private let screenshotCaptureCue = ScreenshotCaptureCuePresenter()
    /// Vision's surface: the real screen with a wash over it, rather than a
    /// panel holding a picture of it (R14).
    private let pointingOverlay = VisionPointingOverlay()
    private var pointingTask: Task<Void, Never>?
    private var composeSession: ComposeSession?
    private var visionSession: VisionSession?
    private var summonTargetApp: NSRunningApplication?
    private var isDictating = false
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionWarmupTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var focusSnapshotTask: Task<AXFocusSnapshot, Never>?
    private var captureGeneration = 0
    /// Full-screen shot taken silently the moment compose is summoned, so a
    /// later Shift double-tap into Vision reuses it with zero capture latency.
    /// Owned here until it is either handed to a VisionSession (which deletes
    /// it on teardown) or discarded when compose exits without using it.
    private var composePreCapture: ScreenshotAttachment?
    private var composePreCaptureTask: Task<Void, Never>?
    /// Which product the summon happened on, resolved from the moment the user
    /// asks for Vision so the first turn already carries its skill. It runs
    /// while the screenshot is being taken, so the wait is absorbed rather than
    /// added. Handed to the VisionSession, which owns it from then on.
    private var visionIdentityTask: Task<VisionObservationCaptureService.TargetIdentity?, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var visionStartWatchdog: Task<Void, Never>?
    private var composeGeneration = 0
    /// Whether an editable field was focused in the source app at the moment
    /// compose was summoned — captured synchronously before our panel steals
    /// focus, so the proactive suggestion gate is reliable.
    private var composeFocusEditable = false
    /// The summoned field's frame in global Cocoa coordinates, when the AX
    /// snapshot measured one. The compose bubble opens beside it — input
    /// completion belongs next to the input — and falls back to the screen
    /// centre when nothing was measured.
    private var composeAnchorFrame: CGRect?
    /// True from the 自動返信 button being pressed until that request resolves.
    /// It lets one explicit request through the gates that keep the automatic
    /// path polite (the always-on setting, the empty-draft rule): a user who
    /// pressed the button has already said they want it, whatever the toggle
    /// says and whatever is in the field.
    private var composeSuggestionExplicitlyRequested = false
    /// Reset by every gesture that starts a surface, and read by everything
    /// downstream. Without a shared origin the trail holds several stopwatches
    /// that overlap and cannot be added, and none of them covers the gap the
    /// user notices first: gesture to panel.
    private var summonClock = SummonClock()

    init() {
        panelController.onCloseRequested = { [weak self] in
            self?.handle(.closeRequested)
        }
        stateMachine.onTransition = { [weak self] _, next, _ in
            self?.applyPanel(for: next)
        }
        Diagnostics.record("coordinator.started", mode: stateMachine.mode)
    }

    func setProactiveSuggestionEnabled(_ isEnabled: Bool) {
        guard stateMachine.mode == .compose, let composeSession else { return }
        if !isEnabled {
            suggestionTask?.cancel()
            suggestionTask = nil
            if composeSession.suggestionStatus == .ready {
                SuggestTrace.log("disabled for future sessions; keeping ready draft")
            } else {
                composeSession.resetSuggestion()
                SuggestTrace.log("disabled from compose panel; pending state cleared")
            }
            return
        }

        guard composeSession.isEmptyDraft else { return }
        guard ScreenCapturePermission.isGranted,
              composeFocusEditable,
              GatewaySuggestClient.make() != nil else {
            composeSession.markSuggestionUnavailable()
            return
        }
        composeSession.markSuggestionPreparing()
        if let attachment = composePreCapture {
            maybeStartComposeSuggestion(
                attachment: attachment,
                generation: composeGeneration
            )
        } else if composePreCaptureTask == nil {
            composeSession.markSuggestionUnavailable()
        }
    }

    /// The 自動返信 button: one suggestion, now, whatever the always-on toggle
    /// says. An explicit press takes the result surface over from a review —
    /// the mirror of a review claiming it — and reuses the summon's silent
    /// pre-capture while it is still in hand, so the reply is about the screen
    /// the user summoned us from. When that shot is already spent or failed,
    /// a new one is taken for this request.
    func requestComposeSuggestionNow() {
        guard stateMachine.mode == .compose, let composeSession else { return }
        guard composeSession.suggestionStatus != .preparing else { return }
        guard ScreenCapturePermission.isGranted else {
            composeSession.takeDownReviewSurface()
            composeSession.markSuggestionFailed(
                "自動返信には画面収録の許可が必要です。システム設定の"
                    + "「プライバシーとセキュリティ」から画面収録を許可してください。"
            )
            return
        }
        guard GatewaySuggestClient.make() != nil else {
            composeSession.takeDownReviewSurface()
            composeSession.markSuggestionFailed(
                "文案サービスを利用できません。ログイン状態を確認してください。"
            )
            return
        }
        SuggestTrace.log("explicit request from the compose bubble")
        composeSuggestionExplicitlyRequested = true
        composeSession.takeDownReviewSurface()
        composeSession.markSuggestionPreparing()
        if let attachment = composePreCapture {
            maybeStartComposeSuggestion(
                attachment: attachment,
                generation: composeGeneration
            )
        } else if composePreCaptureTask == nil {
            startComposePreCapture()
        }
        // A capture still in flight needs nothing from here: its completion
        // calls maybeStartComposeSuggestion, and the explicit flag is up.
    }

    /// Single entry point for all input events.
    func handle(_ event: AppEvent) {
        let mode = stateMachine.mode
        Diagnostics.record("coordinator.event", mode: mode, details: [("event", .code(event))])
        switch event {
        case .doubleTap:
            handleDoubleTap(in: mode)
        case .menuPanelToggle:
            if mode == .idle {
                summonCompose()
            } else {
                close(reason: .menuPanelToggle)
            }
        case .screenshotCaptureRequested:
            guard mode == .compose else { return }
            beginVisionCaptureFromCompose()
        case .closeRequested:
            close(reason: .closeRequested)
        case .appResignedActive:
            guard let spec = PanelSpec.forMode(mode), spec.closesOnResignActive else { return }
            close(reason: .resignActive)
        case .singleTap:
            guard mode == .compose else { return }
            composeSession?.toggleFocusedField()
        case .longPressBegan:
            if mode == .idle {
                summonCompose()
            }
            startDictation()
        case .longPressEnded:
            stopDictationAndTranscribe()
        }
    }

    // MARK: - Event handling per mode

    private func handleDoubleTap(in mode: AppMode) {
        switch mode {
        case .idle:
            summonSelectionAware()
        case .vision, .copilot:
            close(reason: .doubleTapOnVision)
        case .compose:
            // The cycle is 閉 → コンポーズ → Vision → 閉: a double-tap always
            // advances compose to Vision. Review is an explicit button, never
            // this gesture. Reuse the silent pre-capture for an instant entry;
            // fall back to the interactive capture when none is ready.
            guard composeSession != nil else { return }
            if !enterVisionReusingPreCapture() {
                beginVisionCaptureFromCompose()
            }
        case .capturing(let returnTo):
            // Abandon the capture session entirely: back to standby.
            _ = returnTo
            close(reason: .doubleTapDuringCapture)
        }
    }

    /// Right-Shift double-tap from idle. One value-only AX snapshot decides the
    /// destination: a meaningful selection → Focused Vision, otherwise an
    /// editable field → Compose, everything else → ordinary Vision. Screenshot
    /// capture runs beside the bounded AX read; no synthetic copy or fixed wait
    /// touches the user's clipboard.
    private func summonSelectionAware() {
        guard stateMachine.mode == .idle else { return }
        summonClock = SummonClock()
        let targetApp = NSWorkspace.shared.frontmostApplication
        summonTargetApp = targetApp
        // Resolve the working screen while that app is still frontmost; once our
        // panel activates, the frontmost app is us.
        ActiveDisplay.pin(to: targetApp)
        let targetPID = targetApp?.processIdentifier ?? 0
        let snapshotTask = AXFocusSnapshotService.snapshotTask(pid: targetPID)
        focusSnapshotTask?.cancel()
        focusSnapshotTask = snapshotTask
        visionIdentityTask = VisionObservationCaptureService.identityTask(
            preferredPID: targetApp?.processIdentifier
        )
        guard stateMachine.transition(
            to: .capturing(returnTo: .idle),
            reason: .idleAXFocusSummon
        )
        else { return }

        let startedAt = Date()
        captureGeneration += 1
        let generation = captureGeneration
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            let displayID = ActiveDisplay.displayID(of: ActiveDisplay.screen())
            let completion: CaptureCompletion
            if ScreenCapturePermission.isGranted {
                do {
                    let attachment = try await self.screenshotCapture.captureFullScreen(
                        displayID: displayID
                    )
                    completion = .attachment(attachment)
                } catch {
                    completion = .failed(UserFacingError.message(for: error))
                }
            } else {
                completion = .failed(
                    "Visionには画面収録の許可が必要です。システム設定の"
                        + "「プライバシーとセキュリティ」から画面収録を許可してください。"
                )
            }
            let snapshot = await snapshotTask.value
            guard !Task.isCancelled else {
                if case .attachment(let attachment) = completion {
                    try? FileManager.default.removeItem(at: attachment.url)
                }
                return
            }
            await MainActor.run {
                guard self.captureGeneration == generation,
                      case .capturing(returnTo: .idle) = self.stateMachine.mode else {
                    if case .attachment(let attachment) = completion {
                        try? FileManager.default.removeItem(at: attachment.url)
                    }
                    return
                }
                self.captureTask = nil
                self.focusSnapshotTask = nil
                Diagnostics.record(
                    "coordinator.axFocusResolved",
                    mode: self.stateMachine.mode,
                    details: [
                        ("sinceSummon", .ms(self.summonClock.elapsedMs)),
                        ("elapsed", .ms(Int(Date().timeIntervalSince(startedAt) * 1_000))),
                        ("passes", .count(snapshot.collectionPasses)),
                        ("status", .code(snapshot.status)),
                        ("destination", .code(AXFocusLaunchDecision.destination(for: snapshot))),
                    ]
                )
                self.completeIdleSummon(snapshot: snapshot, capture: completion)
            }
        }
    }

    private func completeIdleSummon(
        snapshot: AXFocusSnapshot,
        capture: CaptureCompletion
    ) {
        switch AXFocusLaunchDecision.destination(for: snapshot) {
        case .compose:
            visionIdentityTask?.cancel()
            visionIdentityTask = nil
            let preCapture: ScreenshotAttachment?
            if case .attachment(let attachment) = capture {
                preCapture = attachment
            } else {
                preCapture = nil
            }
            presentComposeSession(
                focusEditable: snapshot.isEditable,
                preCapture: preCapture,
                anchorFrame: Self.cocoaFrame(fromAXFrame: snapshot.frame)
            )
        case .vision:
            handleVisionCaptureCompletion(
                capture,
                composeSession: nil,
                selection: AXFocusLaunchDecision.selectionExtension(for: snapshot)
            )
        }
    }

    /// Idle summon routes that should never inspect the current selection
    /// (menu-bar command, hold-to-talk bootstrap) always open compose.
    private func summonCompose() {
        guard stateMachine.mode == .idle else { return }
        summonClock = SummonClock()
        presentComposeSession()
    }

    /// Where the compose bubble ended up opening, as a closed vocabulary.
    ///
    /// Recorded because the difference is invisible from the outside: a bubble
    /// in the centre looks the same whether the field was never measured or the
    /// measurement was thrown away, and telling those apart from a screenshot
    /// is guessing. Never the coordinates themselves — the trail carries codes
    /// and counts, not places (README「データ保存」).
    enum ComposeAnchorPlacement: String, DiagnosticCode {
        case besideField
        case centre

        var diagnosticCode: String { rawValue }
    }

    /// An AX frame in Cocoa global coordinates, for sitting the bubble beside
    /// the field the user summoned from.
    ///
    /// The arithmetic is `VisionPointerResolver`'s, not this file's. It briefly
    /// was this file's, with the main display's height read a second way
    /// (`NSScreen.screens.first?.frame.maxY`); the two spellings agree, which
    /// is exactly why keeping both was a trap.
    private static func cocoaFrame(fromAXFrame frame: CGRect?) -> CGRect? {
        VisionPointerResolver.cocoaGlobalRect(
            axFrame: frame,
            mainDisplayHeight: VisionPointerResolver.mainDisplayHeight
        )
    }

    /// Compose summon captures the paste target and L1 context before the
    /// panel activates and steals focus from the originating app.
    private func presentComposeSession(
        focusEditable: Bool? = nil,
        preCapture: ScreenshotAttachment? = nil,
        anchorFrame: CGRect? = nil
    ) {
        let target = NSWorkspace.shared.frontmostApplication
        summonTargetApp = target
        // Both of these read the source app while it is still frontmost: the
        // screen it is on, and whether it has an editable field focused. After
        // our panel activates, neither is answerable.
        ActiveDisplay.pin(to: target)
        // Capture focus editability — and where the field is — synchronously,
        // before the panel activates and the source app loses first responder.
        //
        // Both come from the one read. The double-tap has already taken its own
        // AX snapshot and passes both in; the summons that have not (hold to
        // talk, the menu bar) do it here, and this is the only chance: after
        // activation the source app no longer reports a focused element.
        let verdict = focusEditable == nil
            ? target.flatMap {
                SituationalContextService.focusedFieldVerdict(pid: $0.processIdentifier)
            }
            : nil
        composeFocusEditable = focusEditable ?? verdict?.isEditable ?? false
        // Beside the field only when it *is* the field being written into. An
        // element that is not editable is not the subject of input completion,
        // and a secure field is one this product keeps away from — sitting
        // beside either would be pointing at the wrong thing rather than
        // opening where the work is.
        composeAnchorFrame = anchorFrame
            ?? (composeFocusEditable
                ? Self.cocoaFrame(fromAXFrame: verdict?.frame)
                : nil)
        Diagnostics.record("coordinator.composeAnchor", mode: stateMachine.mode, details: [
            ("placement", .code(composeAnchorFrame == nil
                ? ComposeAnchorPlacement.centre
                : ComposeAnchorPlacement.besideField)),
            ("editable", .flag(composeFocusEditable)),
        ])
        composeSuggestionExplicitlyRequested = false
        let rootContextTask = SituationalContextService.captureTask()
        let deployer = PasteDeployer(targetApp: target) { [weak self] in
            self?.close(reason: .composeDeploy)
        }
        let session = ComposeSession(
            deployer: deployer,
            contextCaptureTask: Task { await rootContextTask.value }
        )
        visionSession?.tearDown()
        session.onToggleDictation = { [weak self] in self?.toggleDictation() }
        session.onRequestSuggestion = { [weak self] in self?.requestComposeSuggestionNow() }
        visionSession = nil
        composeSession = session
        guard stateMachine.transition(to: .compose, reason: .summon) else {
            session.tearDown()
            composeSession = nil
            summonTargetApp = nil
            if let preCapture {
                try? FileManager.default.removeItem(at: preCapture.url)
            }
            return
        }
        Task {
            await GatewayAIWarmup.warm([.suggest, .review, .vision])
        }
        // Reserve the suggestion slot immediately (placeholder + loading) when
        // we intend to try, so it's present from the moment the panel opens and
        // the panel doesn't grow-then-shrink later. Resolved to ready/none once
        // the request completes; retracted if the pre-capture can't run.
        if AppSettings.isProactiveSuggestEnabled(),
           composeFocusEditable,
           ScreenCapturePermission.isGranted,
           GatewaySuggestClient.make() != nil {
            session.markSuggestionPreparing()
        }
        if let preCapture {
            adoptComposePreCapture(preCapture)
        } else {
            startComposePreCapture()
        }
    }

    private func close(reason: TransitionReason) {
        guard stateMachine.mode != .idle else { return }
        // Explicit dismissal should put the user back where the panel was
        // summoned from. Without this, Universal I/O can remain the frontmost
        // accessory app after its last window is ordered out; the next summon
        // then sees our own pid, concludes that no editable field is focused,
        // and incorrectly routes straight to Vision. Never steal focus back
        // when the panel closed because the user activated another app, and let
        // PasteDeployer own the timed activation used by an actual send.
        let appToRestore: NSRunningApplication? =
            reason == .resignActive || reason == .composeDeploy
            ? nil
            : summonTargetApp
        // Teardown may not outrun the state machine. When a transition is
        // refused the app is still in its previous mode, and cancelling the
        // requests plus deleting the capture would leave the panel on screen
        // with nothing behind it — the hollow panel this project exists to
        // prevent (docs/reliability-hardening-plan.md D6).
        guard stateMachine.transition(to: .idle, reason: reason) else {
            Diagnostics.record(
                "coordinator.closeRefused",
                mode: stateMachine.mode,
                details: [("reason", .code(reason))]
            )
            return
        }
        stopActiveWork()
        discardComposePreCapture()
        visionIdentityTask = nil
        composeAnchorFrame = nil
        composeSuggestionExplicitlyRequested = false
        composeSession?.tearDown()
        composeSession = nil
        visionSession?.tearDown()
        visionSession = nil
        summonTargetApp = nil
        ActiveDisplay.unpin()
        if let appToRestore, !appToRestore.isTerminated {
            appToRestore.activate()
        }
    }

    // MARK: - Dictation

    /// The button's way in, which the key does not have: something to press
    /// again.
    ///
    /// Hold-to-talk ends when the key comes up, and a button has nothing to come
    /// up — so the two gestures share the start and the stop but not the shape.
    /// Both go through the same pair, so a session started either way is
    /// finished, transcribed and cleaned up by the same code.
    func toggleDictation() {
        if isDictating {
            stopDictationAndTranscribe()
        } else {
            startDictation()
        }
    }

    private func startDictation() {
        guard !isDictating else { return }
        transcriptionWarmupTask?.cancel()
        transcriptionWarmupTask = Task {
            await GatewayAIWarmup.warm([.transcribe])
        }
        switch stateMachine.mode {
        case .compose:
            guard let composeSession else { return }
            isDictating = true
            composeSession.errorMessage = nil
            composeSession.isRecording = true
            SoundFeedback.recordingStarted()
            do {
                try recorder.start()
            } catch {
                isDictating = false
                composeSession.isRecording = false
                composeSession.errorMessage = UserFacingError.message(for: error)
            }
        case .vision, .copilot:
            guard let visionSession else { return }
            isDictating = true
            visionSession.errorMessage = nil
            visionSession.isRecording = true
            visionSession.focusedField = .navigator
            SoundFeedback.recordingStarted()
            do {
                try recorder.start()
            } catch {
                isDictating = false
                visionSession.isRecording = false
                visionSession.errorMessage = UserFacingError.message(for: error)
            }
        default:
            return
        }
    }

    private func stopDictationAndTranscribe() {
        guard isDictating else { return }
        isDictating = false
        recorder.onFinish = { SoundFeedback.recordingStopped() }
        guard let url = recorder.stop() else {
            composeSession?.isRecording = false
            visionSession?.isRecording = false
            return
        }

        enum DictationSink {
            case compose(ComposeSession)
            case vision(VisionSession)
        }

        let sink: DictationSink?
        switch stateMachine.mode {
        case .compose:
            if let composeSession {
                composeSession.isRecording = false
                composeSession.isTranscribing = true
                sink = .compose(composeSession)
            } else {
                sink = nil
            }
        case .vision, .copilot:
            if let visionSession {
                visionSession.isRecording = false
                visionSession.isTranscribing = true
                sink = .vision(visionSession)
            } else {
                sink = nil
            }
        default:
            sink = nil
        }
        guard let sink else { return }

        OperationalNoticeCenter.shared.beginOperation()
        guard let transcriber = GatewayTranscriber.make() else {
            switch sink {
            case .compose(let composeSession):
                composeSession.isTranscribing = false
                composeSession.errorMessage = "文字起こしサービスを利用できません。ログイン状態を確認してください。"
            case .vision(let visionSession):
                visionSession.isTranscribing = false
                visionSession.errorMessage = "文字起こしサービスを利用できません。ログイン状態を確認してください。"
            }
            try? FileManager.default.removeItem(at: url)
            return
        }

        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: url) }
            guard let self else { return }

            await self.transcriptionWarmupTask?.value
            self.transcriptionWarmupTask = nil

            if let clip = AudioRecorder.inspect(url: url),
               clip.duration < 0.4 || clip.averagePower < -45 {
                switch sink {
                case .compose(let composeSession):
                    if self.composeSession === composeSession {
                        composeSession.isTranscribing = false
                    }
                case .vision(let session):
                    if self.visionSession === session {
                        session.isTranscribing = false
                    }
                }
                return
            }

            do {
                let text = try await transcriber.transcribe(fileURL: url)
                try Task.checkCancellation()
                switch sink {
                case .compose(let composeSession):
                    guard self.composeSession === composeSession,
                          self.stateMachine.mode == .compose else { return }
                    composeSession.appendTranscription(text)
                    composeSession.isTranscribing = false
                case .vision(let session):
                    guard self.visionSession === session,
                          self.stateMachine.mode == .vision else { return }
                    session.appendTranscription(text)
                    session.isTranscribing = false
                }
            } catch is CancellationError {
                return
            } catch {
                switch sink {
                case .compose(let composeSession):
                    guard self.composeSession === composeSession else { return }
                    composeSession.isTranscribing = false
                    composeSession.errorMessage =
                        "文字起こしに失敗しました。もう一度お試しください。"
                case .vision(let session):
                    guard self.visionSession === session else { return }
                    session.isTranscribing = false
                    session.errorMessage =
                        "文字起こしに失敗しました。もう一度お試しください。"
                }
            }
        }
    }

    /// Watches for the one failure this project exists to eliminate: the app
    /// entered vision, and no request ever left. The session start is now
    /// synchronous and coordinator-owned (D2), so this should never fire — but
    /// "should never" is exactly what was believed about the appearance
    /// callback. A retry costs one duplicate request; a missed start costs the
    /// whole session and tells the user nothing.
    private func superviseVisionStart(_ session: VisionSession) {
        visionStartWatchdog?.cancel()
        visionStartWatchdog = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(OperationDeadline.visionStartWatchdog))
            guard !Task.isCancelled,
                  let session,
                  self?.visionSession === session,
                  session.restartIfNoRequestIssued() else { return }

            try? await Task.sleep(for: .seconds(OperationDeadline.visionStartWatchdog))
            guard !Task.isCancelled, self?.visionSession === session else { return }
            session.reportStartFailure()
        }
    }

    private func stopActiveWork() {
        captureGeneration += 1
        visionStartWatchdog?.cancel()
        visionStartWatchdog = nil
        captureTask?.cancel()
        captureTask = nil
        focusSnapshotTask?.cancel()
        focusSnapshotTask = nil
        suggestionTask?.cancel()
        suggestionTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if isDictating {
            isDictating = false
            recorder.onFinish = { SoundFeedback.recordingStopped() }
            if let url = recorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
        }
        composeSession?.isRecording = false
        composeSession?.isTranscribing = false
        visionSession?.isRecording = false
        visionSession?.isTranscribing = false
    }

    // MARK: - Compose pre-capture (shared with Vision)

    /// The user summoning compose is already an intent to use the tool, so we
    /// grab the screen the moment the panel opens. The shot is silent (no
    /// selection overlay) and excludes our own windows. It is only started
    /// when screen recording is already granted — summoning must never trigger
    /// a permission prompt.
    private func startComposePreCapture() {
        discardComposePreCapture()
        guard ScreenCapturePermission.isGranted else {
            SuggestTrace.log("pre-capture skipped: screen recording not granted")
            return
        }
        composeGeneration += 1
        let generation = composeGeneration
        composePreCaptureTask = Task { [weak self] in
            let displayID = ActiveDisplay.displayID(of: ActiveDisplay.screen())
            let attachment = try? await ScreenshotCaptureService().captureFullScreen(displayID: displayID)
            await MainActor.run {
                guard let self else {
                    if let attachment { try? FileManager.default.removeItem(at: attachment.url) }
                    return
                }
                self.composePreCaptureTask = nil
                // A slow shot must not land into a newer session or a mode the
                // pre-capture no longer serves.
                guard self.composeGeneration == generation, self.stateMachine.mode == .compose else {
                    if let attachment { try? FileManager.default.removeItem(at: attachment.url) }
                    return
                }
                self.composePreCapture = attachment
                if let attachment {
                    self.maybeStartComposeSuggestion(attachment: attachment, generation: generation)
                } else if self.composeSession?.suggestionStatus == .preparing {
                    // Promised a suggestion but the capture produced no image.
                    // That is a failure, not "no candidate" — say which.
                    self.composeSession?.markSuggestionFailed(
                        "画面を取得できなかったため、文案を作れませんでした。",
                        detail: "compose pre-capture returned no image"
                    )
                }
            }
        }
    }

    /// A right-Shift summon already captured the screen beside its AX read.
    /// Keep that exact image as Compose's pre-capture instead of taking a
    /// second shot after the panel has opened.
    private func adoptComposePreCapture(_ attachment: ScreenshotAttachment) {
        discardComposePreCapture()
        composeGeneration += 1
        let generation = composeGeneration
        composePreCapture = attachment
        maybeStartComposeSuggestion(attachment: attachment, generation: generation)
    }

    /// Ask the Gateway for a proactive draft for the focused external field,
    /// reusing the shared pre-capture. Gated by the user setting; the image
    /// pre-capture itself always runs (it also serves Vision speed). The image
    /// file stays owned here — the suggest client only reads its bytes — so a
    /// later Vision entry can still reuse it.
    private func maybeStartComposeSuggestion(
        attachment: ScreenshotAttachment,
        generation: Int
    ) {
        // If a placeholder was reserved at summon but a precondition no longer
        // holds, resolve it to the clear "none" state rather than leaving it
        // spinning forever.
        func retractPlaceholder() {
            if self.composeSession?.suggestionStatus == .preparing {
                self.composeSession?.markSuggestionUnavailable()
            }
        }

        // One explicit press opens every politeness gate below. The always-on
        // setting, the empty-draft rule and the editable-focus requirement all
        // exist so the automatic path never spends a model call the user did
        // not ask for — and this one they asked for by name.
        let explicitlyRequested = composeSuggestionExplicitlyRequested
        guard AppSettings.isProactiveSuggestEnabled() || explicitlyRequested else {
            SuggestTrace.log("skip: feature disabled")
            retractPlaceholder()
            return
        }
        guard let composeSession, explicitlyRequested || composeSession.isEmptyDraft else {
            SuggestTrace.log("skip: no session or draft not empty")
            retractPlaceholder()
            return
        }
        guard let client = GatewaySuggestClient.make() else {
            SuggestTrace.log("skip: gateway client unavailable (signed in?)")
            retractPlaceholder()
            return
        }

        // Focus was read synchronously at summon (composeFocusEditable); with
        // the new routing, compose is normally only reached when a field was
        // focused, but guard here too so other summon paths (menu, hold-to-talk)
        // don't spend a model call with no target field.
        guard explicitlyRequested || composeFocusEditable else {
            SuggestTrace.log("skip: no editable field focused at summon")
            retractPlaceholder()
            return
        }

        let session = composeSession
        let captureID = attachment.id
        // Consumed by the request it lets through: the next automatic pass
        // answers to the ordinary gates again.
        composeSuggestionExplicitlyRequested = false
        suggestionTask?.cancel()
        suggestionTask = Task { [weak self] in
            guard let self else { return }
            let context = await session.awaitSituationalContext()
            SuggestTrace.log("context app=\(context?.appName ?? "nil"); requesting suggestion…")
            await MainActor.run {
                guard self.composeGeneration == generation,
                      self.composeSession === session,
                      self.stateMachine.mode == .compose else { return }
                session.markSuggestionPreparing()
            }
            do {
                let suggestion = try await client.suggest(
                    attachment: attachment,
                    context: context,
                    language: AppSettings.outputLanguage()
                )
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.composeGeneration == generation,
                          self.composeSession === session,
                          self.stateMachine.mode == .compose else { return }
                    self.suggestionTask = nil
                    guard suggestion.captureID == captureID else { return }
                    SuggestTrace.log("ready: draftChars=\(suggestion.draft.count)")
                    session.applySuggestion(
                        draft: suggestion.draft,
                        note: suggestion.note,
                        skillName: suggestion.skillName
                    )
                    // Independent of whether a draft came back: the screen may
                    // establish who the user is even when it offers nothing to
                    // write. Presented after, so it never displaces the draft.
                    session.presentFactQuestion(suggestion.factQuestion)
                }
            } catch is CancellationError {
                return
            } catch {
                SuggestTrace.log("failed: \(error.localizedDescription)")
                await MainActor.run {
                    guard self.composeGeneration == generation,
                          self.composeSession === session,
                          self.stateMachine.mode == .compose else { return }
                    self.suggestionTask = nil
                    // A failed request is not "the model had nothing to say".
                    // Surface the real reason — collapsing it into the empty
                    // state is what made a dead endpoint look like a quiet one.
                    session.markSuggestionFailed(
                        UserFacingError.message(for: error),
                        detail: Self.technicalDetail(for: error)
                    )
                }
            }
        }
    }

    /// Compact technical cause shown under the friendly message, so a real
    /// failure (missing endpoint, 5xx, transport) is identifiable instead of
    /// being flattened into generic copy.
    private static func technicalDetail(for error: Error) -> String {
        let nsError = error as NSError
        let raw = error.localizedDescription
        return "\(nsError.domain) \(nsError.code): \(raw)"
    }

    /// Enter Vision reusing the silent pre-capture, skipping the interactive
    /// overlay entirely. Ownership of the image transfers to the VisionSession.
    /// Returns false when no pre-capture is ready (caller falls back).
    private func enterVisionReusingPreCapture() -> Bool {
        guard let composeSession, let attachment = composePreCapture else { return false }
        // The double-tap just happened and the shot is already in hand, so
        // everything from here is the app's wait.
        summonClock = SummonClock()
        composePreCapture = nil
        composePreCaptureTask?.cancel()
        composePreCaptureTask = nil
        guard stateMachine.transition(to: .capturing(returnTo: .compose), reason: .composePreCaptureVision)
        else {
            try? FileManager.default.removeItem(at: attachment.url)
            return false
        }
        handleVisionCaptureCompletion(.attachment(attachment), composeSession: composeSession)
        return true
    }

    /// Drop an unused pre-capture: cancel a still-running shot and delete a
    /// finished one so no temporary image outlives its compose session.
    private func discardComposePreCapture() {
        composePreCaptureTask?.cancel()
        composePreCaptureTask = nil
        if let attachment = composePreCapture {
            try? FileManager.default.removeItem(at: attachment.url)
            composePreCapture = nil
        }
    }

    // MARK: - Vision capture

    private func beginVisionCaptureFromCompose() {
        discardComposePreCapture()
        guard let composeSession else { return }
        guard ScreenCapturePermission.isGranted || ScreenCapturePermission.request() else {
            composeSession.errorMessage = "スクリーンショットには画面収録の許可が必要です。"
            return
        }
        guard stateMachine.transition(to: .capturing(returnTo: .compose), reason: .emptyComposeCapture)
        else {
            return
        }

        captureGeneration += 1
        let generation = captureGeneration
        captureTask?.cancel()
        captureTask = Task { [weak self, weak composeSession] in
            guard let self, let composeSession else { return }

            let screen = ActiveDisplay.screen()
            let displayID = ActiveDisplay.displayID(of: screen)

            let completion: CaptureCompletion
            do {
                let attachment = try await self.captureAttachment(on: screen, displayID: displayID)
                completion = .attachment(attachment)
            } catch ScreenshotCaptureError.cancelled {
                completion = .cancelled
            } catch {
                completion = .failed(UserFacingError.message(for: error))
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.captureGeneration == generation else { return }
                self.captureTask = nil
                // This route puts a selection overlay up and waits for the user
                // to drag a region. That is their time, not ours, so the
                // measured wait starts where the app takes over again.
                self.summonClock = SummonClock()
                self.handleVisionCaptureCompletion(completion, composeSession: composeSession)
            }
        }
    }

    private func handleVisionCaptureCompletion(
        _ completion: CaptureCompletion,
        composeSession: ComposeSession?,
        selection: VisionSelectionContext? = nil
    ) {
        // Any entry into a VisionSession retires the pending compose suggestion.
        suggestionTask?.cancel()
        suggestionTask = nil
        let pendingIdentity = visionIdentityTask
        visionIdentityTask = nil
        guard case .capturing(let returnTo) = stateMachine.mode else { return }

        switch completion {
        case .attachment(let attachment):
            let resolvedSelection = selection?.resolvingCaptureVisibility(for: attachment)
            let candidateCaptureTask = VisionObservationCaptureService.captureTask(
                preferredPID: summonTargetApp?.processIdentifier,
                attachment: attachment
            )
            let identityTask = resolveVisionIdentityTask(
                from: composeSession,
                pending: pendingIdentity
            )
            let session = VisionSession(
                attachment: attachment,
                preferredTargetPID: summonTargetApp?.processIdentifier,
                candidateCaptureTask: candidateCaptureTask,
                identityTask: identityTask,
                selection: resolvedSelection,
                askClock: summonClock,
                onRequestModeTransition: { [weak self] target, reason in
                    self?.transitionVision(to: target, reason: reason) ?? false
                },
                onRequestPanelClose: { [weak self] in
                    self?.close(reason: .visionRequestedClose)
                },
                bubbleFrame: { [weak self] in self?.pointingOverlay.bubbleCardFrame }
            )
            visionSession?.tearDown()
            session.onToggleDictation = { [weak self] in self?.toggleDictation() }
            visionSession = session
            guard stateMachine.transition(to: .vision, reason: .captureCompleted) else {
                session.tearDown()
                visionSession = nil
                _ = stateMachine.transition(to: returnTo, reason: .captureTransitionFailed)
                return
            }
            // The panel appearing is a CONSEQUENCE of the transition above, not
            // a precondition for asking. Vision used to start from the SwiftUI
            // `.task`, so a summon whose appearance callback never fired issued
            // no request, showed no spinner, and reported no error — the
            // 2026-08-03 stall (docs/reliability-hardening-plan.md §2). Compose
            // has always been shaped this way; Vision was the exception.
            session.startIfNeeded()
            superviseVisionStart(session)
        case .cancelled:
            _ = stateMachine.transition(to: returnTo, reason: .captureCancelled)
        case .failed(let message):
            composeSession?.errorMessage = message
            _ = stateMachine.transition(to: returnTo, reason: .captureFailed)
        }
    }

    /// Where the product identity for a Vision session comes from, best source
    /// first: the compose session, which resolved it at its own summon and is
    /// therefore both free and warm; a task started when Vision was summoned
    /// from idle; or, as a last resort, a fresh lookup.
    private func resolveVisionIdentityTask(
        from composeSession: ComposeSession?,
        pending: Task<VisionObservationCaptureService.TargetIdentity?, Never>?
    ) -> Task<VisionObservationCaptureService.TargetIdentity?, Never> {
        if let composeSession {
            let fallbackPID = summonTargetApp?.processIdentifier
            return Task {
                if let context = await composeSession.awaitSituationalContext() {
                    return VisionObservationCaptureService.TargetIdentity(context: context)
                }
                return await VisionObservationCaptureService
                    .identityTask(preferredPID: fallbackPID)
                    .value
            }
        }
        return pending ?? VisionObservationCaptureService.identityTask(
            preferredPID: summonTargetApp?.processIdentifier
        )
    }

    private func transitionVision(to target: AppMode, reason: TransitionReason) -> Bool {
        guard visionSession != nil else { return false }
        return stateMachine.transition(to: target, reason: reason)
    }

    /// The shot Vision opens with.
    ///
    /// This used to put a selection overlay up and wait: the whole screen was
    /// pre-selected, Enter confirmed it, dragging took a region instead. The
    /// wait is gone (R14). Entering Vision now reads the screen immediately and
    /// the first sentence is already on its way, because a confirmation step in
    /// front of an explanation nobody asked to confirm is a step that only ever
    /// gets pressed.
    ///
    /// Choosing a smaller area comes back as a gesture on the pointing overlay,
    /// where drawing a ring around something already means "this part" — the
    /// same operation without a mode in front of it.
    private func captureAttachment(
        on screen: NSScreen?,
        displayID: CGDirectDisplayID?
    ) async throws -> ScreenshotAttachment {
        guard screen != nil else { throw ScreenshotCaptureError.noCaptureTarget }
        do {
            return try await screenshotCapture.captureFullScreen(displayID: displayID)
        } catch ScreenshotCaptureError.cancelled {
            throw ScreenshotCaptureError.cancelled
        } catch {
            NSLog(
                "Vision capture failed (display=%@): %@",
                displayID.map(String.init) ?? "nil",
                String(describing: error)
            )
            OperationalNoticeCenter.shared.publish(
                code: "CAPTURE_FALLBACK",
                message: "ScreenCaptureKitで撮影できなかったため、macOS標準のスクリーンショット撮影に切り替えました。"
            )
            await screenshotCaptureCue.showBriefly()
            return try await screenshotCapture.captureInteractive()
        }
    }

    // MARK: - Panel

    private func applyPanel(for mode: AppMode) {
        switch mode {
        case .compose:
            guard let composeSession else { return }
            // The first thing the user sees. Recorded before `present` returns
            // rather than after, because what follows is view construction the
            // user is already watching happen, and because a panel that never
            // finishes appearing must still leave the attempt in the trail.
            if !panelController.isVisible {
                Diagnostics.record("coordinator.panelShown", mode: mode, details: [
                    ("sinceSummon", .ms(summonClock.elapsedMs)),
                ])
            }
            panelController.presentCompose(
                FoundationComposeRootView(
                    session: composeSession,
                    // The only place that knows which display the bubble is
                    // for, so the only place that can say how much room the
                    // growing surfaces may share — same contract as Vision.
                    heightBudget: ComposeBubbleView.heightBudget(
                        visibleHeight: (ActiveDisplay.screen() ?? NSScreen.main)?
                            .visibleFrame.height ?? 900
                    ),
                    onClose: { [weak self] in self?.close(reason: .closeRequested) }
                ),
                anchorFrame: composeAnchorFrame
            )
        case .vision:
            guard let visionSession else { return }
            if pointingOverlay.isVisible {
                // Back from guidance: the same overlay, with the wash returning.
                pointingOverlay.enterPointing()
            } else {
                Diagnostics.record("coordinator.panelShown", mode: mode, details: [
                    ("sinceSummon", .ms(summonClock.elapsedMs)),
                ])
                presentPointing(for: visionSession)
            }
        case .copilot:
            // Guidance presents nothing new. It is the pointing overlay with the
            // wash lifted, so the clicks the user is asked to make reach the app
            // underneath, and the bubble that was explaining now instructs. The
            // strip this used to present is gone (R15).
            pointingOverlay.enterGuiding()
        case .capturing:
            panelController.hide()
        case .idle:
            pointingTask?.cancel()
            pointingTask = nil
            pointingOverlay.close()
            panelController.close()
        }
    }

    // MARK: - Pointing

    private func presentPointing(for session: VisionSession) {
        guard let screen = ActiveDisplay.screen() else { return }
        panelController.close()
        pointingOverlay.onPoint = { [weak self] point in
            self?.point(at: point, session: session)
        }
        pointingOverlay.onRegion = { [weak self] path in
            self?.region(around: path, session: session)
        }
        pointingOverlay.onClose = { [weak self] in
            self?.close(reason: .closeRequested)
        }
        session.onAnswerHighlight = { [weak self] box in
            self?.markWhatTheAnswerIsAbout(box, session: session)
        }
        pointingOverlay.present(
            on: screen,
            bubble: VisionBubbleView(
                session: session,
                // This is the only place that knows which display the overlay
                // ended up on, so it is the only place that can say how much
                // room there is; how much of that room the answer may take is
                // the bubble's own rule.
                answerHeightBudget: VisionBubbleView.answerHeightBudget(
                    visibleHeight: screen.visibleFrame.height
                ),
                onClose: { [weak self] in self?.close(reason: .closeRequested) }
            )
        )
    }

    /// Puts the frame where the answer is actually pointing.
    ///
    /// The place the user clicked and the thing the answer explains are not
    /// always the same: the model reaches for the nearest meaningful element when
    /// the exact pixel falls between things. Of the two, the one worth marking is
    /// the one being explained — a mark on the click beside an answer about
    /// something else tells the user they were misunderstood, while a mark on the
    /// neighbour tells them what was understood, which they can accept or
    /// correct. When no box comes back, their own mark stays: then the gesture is
    /// the only thing that says what the question was about.
    private func markWhatTheAnswerIsAbout(_ box: CGRect?, session: VisionSession) {
        guard pointingOverlay.isVisible else { return }
        guard let box, let captureRect = session.attachment.captureRect else {
            // Nothing to point at — or, in guidance, the user just clicked and
            // the frame on the old control would be a claim about a screen that
            // is changing. The bubble stays where it is.
            pointingOverlay.clearAnswerFrame()
            return
        }
        pointingOverlay.showAnswerFrame(
            VisionPointerResolver.screenLocalRect(
                normalized: box,
                captureRect: captureRect,
                mainDisplayHeight: VisionPointerResolver.mainDisplayHeight,
                screenFrame: pointingOverlay.coveredScreenFrame
            )
        )
    }

    /// A click on the covered screen, turned into a question about that place.
    ///
    /// The mark goes up first, before anything is awaited. The first evidence
    /// that a gesture was heard has to appear where the gesture happened — the
    /// bubble is somewhere else, and a screen that does nothing for half a
    /// second reads as a click that missed.
    ///
    /// The still is taken here, at the gesture, rather than reused from when the
    /// overlay opened. Seconds pass in between, and notifications, animations
    /// and work on another display move the screen in them; burning the mark
    /// into a picture the user has stopped looking at answers about whatever
    /// used to be under their finger.
    private func point(at screenLocal: CGPoint, session: VisionSession) {
        // The ring only. Where the bubble goes is decided once, below, when the
        // accessibility walk has said what is actually there.
        pointingOverlay.showRing(at: screenLocal)
        // Before anything is awaited: the previous answer describes a different
        // place, and leaving it beside this one asserts something false about
        // what the user just pointed at.
        session.beginPointing()
        pointingTask?.cancel()
        let screenFrame = pointingOverlay.coveredScreenFrame
        let mainHeight = VisionPointerResolver.mainDisplayHeight
        pointingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await self.screenshotCapture.captureMatchingScope(
                    of: session.attachment
                )
                try Task.checkCancellation()
                guard let captureRect = capture.captureRect else {
                    try? FileManager.default.removeItem(at: capture.url)
                    session.failPointing("画面のどこを指したか分からなくなりました。もう一度クリックしてください。")
                    return
                }
                let global = VisionPointerResolver.globalCGPoint(
                    cocoaGlobal: CGPoint(
                        x: screenLocal.x + screenFrame.minX,
                        y: screenLocal.y + screenFrame.minY
                    ),
                    mainDisplayHeight: mainHeight
                )
                guard let normalized = VisionPointerResolver.normalized(
                    global, within: captureRect
                ) else {
                    // A click on a display this capture does not cover. Saying
                    // so beats answering about the captured screen's edge.
                    try? FileManager.default.removeItem(at: capture.url)
                    session.failPointing("この画面は読み取り対象に入っていません。もう一度呼び出してください。")
                    return
                }
                let snapshot = await VisionObservationCaptureService.captureTask(
                    preferredPID: self.summonTargetApp?.processIdentifier,
                    attachment: capture
                ).value
                try Task.checkCancellation()
                let hit = VisionPointerResolver.candidate(
                    at: normalized, in: snapshot.axCandidates
                )
                Diagnostics.record("vision.point", details: [
                    ("candidates", .count(snapshot.axCandidates.count)),
                    ("hit", .flag(hit != nil)),
                ])
                // Once per gesture, hit or miss: with a frame the bubble sits
                // beside the element, without one beside the click the ring is
                // already marking. Either way it arrives, rather than moving.
                self.pointingOverlay.setMark(
                    point: screenLocal,
                    frame: hit?.rect.map { rect in
                        VisionPointerResolver.screenLocalRect(
                            normalized: rect,
                            captureRect: captureRect,
                            mainDisplayHeight: mainHeight,
                            screenFrame: screenFrame
                        )
                    }
                )
                session.point(
                    // The hit travels inside the pointer: the Gateway tells the
                    // model which candidate the OS measured under the mark, so
                    // two similar-looking controls cannot trade places.
                    pointer: VisionPointer(
                        kind: .point(normalized),
                        hitCandidateID: hit?.id
                    ),
                    capture: capture,
                    candidates: snapshot.axCandidates,
                    diagnostics: snapshot.diagnostics,
                    hit: hit
                )
            } catch is CancellationError {
                return
            } catch {
                session.failPointing(UserFacingError.message(for: error))
            }
        }
    }

    /// A ring drawn on the covered screen, turned into a question about that
    /// area.
    ///
    /// The same shape as `point(at:)` and deliberately not folded into it: the
    /// two differ in what the answer is about — one element, or an area as a
    /// whole — and every difference between them is in this method rather than
    /// in branches threaded through one.
    ///
    /// No candidate is resolved. Accessibility measures elements, and a ring is
    /// what somebody draws around things that are not one element; naming the
    /// smallest candidate under some point of the path would answer about a
    /// part of what they enclosed.
    private func region(around screenLocalPath: [CGPoint], session: VisionSession) {
        pointingOverlay.setRegion(path: screenLocalPath)
        session.beginPointing()
        pointingTask?.cancel()
        let screenFrame = pointingOverlay.coveredScreenFrame
        let mainHeight = VisionPointerResolver.mainDisplayHeight
        pointingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await self.screenshotCapture.captureMatchingScope(
                    of: session.attachment
                )
                try Task.checkCancellation()
                guard let captureRect = capture.captureRect else {
                    try? FileManager.default.removeItem(at: capture.url)
                    session.failPointing("画面のどこを指したか分からなくなりました。もう一度囲んでください。")
                    return
                }
                // The same two conversions the tap uses, applied to every point
                // of the path. A point that falls outside the captured display
                // is dropped rather than clamped: pulling it to the edge would
                // widen the enclosure to include something never enclosed.
                let normalizedPath = screenLocalPath.compactMap { local in
                    VisionPointerResolver.normalized(
                        VisionPointerResolver.globalCGPoint(
                            cocoaGlobal: CGPoint(
                                x: local.x + screenFrame.minX,
                                y: local.y + screenFrame.minY
                            ),
                            mainDisplayHeight: mainHeight
                        ),
                        within: captureRect
                    )
                }
                guard let region = VisionPointerResolver.normalizedRegion(
                    from: normalizedPath
                ) else {
                    try? FileManager.default.removeItem(at: capture.url)
                    session.failPointing("この画面は読み取り対象に入っていません。もう一度呼び出してください。")
                    return
                }
                let snapshot = await VisionObservationCaptureService.captureTask(
                    preferredPID: self.summonTargetApp?.processIdentifier,
                    attachment: capture
                ).value
                try Task.checkCancellation()
                // How much of the drawn path survived the conversion, so a ring
                // that ran off the captured display is separable from one the
                // model simply read differently.
                Diagnostics.record("vision.region", details: [
                    ("drawn", .count(screenLocalPath.count)),
                    ("kept", .count(normalizedPath.count)),
                    ("candidates", .count(snapshot.axCandidates.count)),
                ])
                session.point(
                    // The path travels for the burn only — the contract carries
                    // the rectangle — so the model sees the ring the user drew
                    // rather than the box around it.
                    pointer: VisionPointer(kind: .region(region), stroke: normalizedPath),
                    capture: capture,
                    candidates: snapshot.axCandidates,
                    diagnostics: snapshot.diagnostics,
                    hit: nil
                )
            } catch is CancellationError {
                return
            } catch {
                session.failPointing(UserFacingError.message(for: error))
            }
        }
    }

}

/// Debug-only trace for the proactive-suggestion path, so a tester can see in
/// Console.app exactly why a suggestion did or did not appear.
enum SuggestTrace {
    static func log(_ message: String) {
        #if DEBUG
        NSLog("[Suggest] %@", message)
        #endif
    }
}
