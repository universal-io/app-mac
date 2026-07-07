import AppKit
import Foundation

/// Result of one screenshot capture flow (overlay → shot), delivered by the
/// host. The host owns the overlay and ScreenCaptureKit mechanics in R1-a.
enum ScreenCaptureFlowOutcome {
    case attachment(ScreenshotAttachment)
    case cancelled
    case failed(String)
}

/// Window-side effects the coordinator needs. AppDelegate implements this in
/// R1-a; R2 replaces it with PanelController + PanelSpec (redesign plan §4-d).
/// Every method is called on the main thread.
protocol SessionCoordinatorHost: AnyObject {
    var isPanelVisible: Bool { get }
    /// Create (if needed) and front the floating panel hosting RootPanelView.
    func presentPanel()
    /// Order out and release the panel window.
    func dismissPanel()
    /// Screen-recording permission check (may show the system prompt).
    func canCaptureScreen() -> Bool
    /// Hide the panel, run the selection overlay + capture, then call
    /// `captureFinished(_:)` back with the outcome.
    func beginScreenshotCapture()
    /// Widen the panel to the two-pane vision layout.
    func applyVisionLayout()
    /// Restore the narrow single-column text layout.
    func applyTextLayout()
    /// Re-front the (hidden) panel after a capture flow ends.
    func restorePanelAfterCapture()
}

/// Owns `AppMode` — the single source of truth for what the app is doing —
/// and the transition table that resolves gestures against it
/// (docs/foundation-redesign-plan.md §4-c). Gesture semantics live here and
/// nowhere else; the host only provides window mechanics.
@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var mode: AppMode = .idle

    private weak var host: SessionCoordinatorHost?
    private let authClient = BombSquadAuthClient.shared
    private let recorder = AudioRecorder()
    /// Resolved per dictation because gateway availability follows sign-in state.
    private var transcriber: any Transcriber { GatewayTranscriber.make() ?? GroqTranscriber() }
    /// Guards against duplicate begin/end callbacks so the cues fire exactly once.
    private var isDictating = false

    /// Objects shared by every session of one panel lifetime (summon → close):
    /// the paste target, its deployer, and the L1 capture started at summon.
    private struct PanelContext {
        let targetApp: NSRunningApplication?
        let deployer: Deployer
        let contextTask: Task<SituationalContext?, Never>
    }
    private var panelContext: PanelContext?

    init(host: SessionCoordinatorHost) {
        self.host = host
    }

    func warmUpRecorder() {
        recorder.warmUp()
    }

    // MARK: - Gesture intents (the transition table; 1:1 with README's spec)

    /// Right-Shift double-tap: summon / review / vision / close.
    /// The capture-overlay abandon path is short-circuited by the host, which
    /// owns the overlay (R1-a; moves here with R1-b).
    func handleDoubleTap() {
        switch mode {
        case .idle:
            summon()
        case .compose(let session):
            guard session.focusedField == .draft else { return }
            if session.isEmptyDraft {
                requestVisionCapture()
            } else {
                session.requestReviewFromHotkey()
            }
        case .transform(let session):
            session.startInterpretation()
        case .legacyVision:
            close()
        case .capturing:
            break
        }
    }

    /// Right-Shift single tap: draft ↔ revision focus (compose only).
    func handleSingleTap() {
        guard case .compose(let session) = mode else { return }
        session.toggleFocusedField()
    }

    /// ⌘J / menu-bar toggle. Unlike the double-tap summon this never grabs a
    /// selection: it opens compose directly (pre-redesign parity).
    func togglePanel() {
        if case .capturing = mode { return }
        if host?.isPanelVisible == true {
            close()
        } else {
            openComposeDirect()
        }
    }

    /// Ends the current session (lifecycle contract §4-b: the old session's
    /// teardown runs here, in the transition, never at scattered call sites)
    /// and closes the panel.
    func close() {
        endCurrentSession()
        panelContext = nil
        host?.dismissPanel()
    }

    private func endCurrentSession() {
        switch mode {
        case .idle:
            break
        case .compose(let session):
            session.willEnd()
        case .transform(let session):
            session.willEnd()
        case .capturing(resume: let session):
            session.willEnd()
        case .legacyVision(let viewModel):
            viewModel.panelWillClose()
        }
        mode = .idle
    }

    // MARK: - Summon

    /// Right-Shift double-tap from standby. If the frontmost app has a text
    /// selection, it becomes a transform session (receiving side); otherwise
    /// an empty compose session. The grab must run before our panel steals
    /// focus, so everything happens in its completion.
    private func summon() {
        SelectionGrabber.grab { [weak self] selection in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Capture the paste target and the L1 context now — after the
                // grab, but before the panel takes focus.
                let target = NSWorkspace.shared.frontmostApplication
                let contextTask = SituationalContextService.captureTask()
                if let selection {
                    self.openTransform(source: selection, contextTask: contextTask)
                } else {
                    self.openCompose(targetApp: target, contextTask: contextTask)
                }
                self.host?.presentPanel()
            }
        }
    }

    private func openComposeDirect() {
        let target = NSWorkspace.shared.frontmostApplication
        let contextTask = SituationalContextService.captureTask()
        openCompose(targetApp: target, contextTask: contextTask)
        host?.presentPanel()
    }

    private func openCompose(
        targetApp: NSRunningApplication?,
        contextTask: Task<SituationalContext?, Never>
    ) {
        let deployer = PasteDeployer(targetApp: targetApp) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.close() }
        }
        panelContext = PanelContext(targetApp: targetApp, deployer: deployer, contextTask: contextTask)
        let session = ComposeSession(deployer: deployer)
        session.restorePersistedDraftIfNeeded()
        session.attachContextCapture(contextTask)
        mode = .compose(session)
    }

    private func openTransform(
        source: String,
        contextTask: Task<SituationalContext?, Never>
    ) {
        // Received message: never write back into the sender's field, so the
        // panel context carries no paste deployer.
        panelContext = PanelContext(targetApp: nil, deployer: ClipboardDeployer(), contextTask: contextTask)
        let session = TransformSession(sourceText: source)
        session.attachContextCapture(contextTask)
        mode = .transform(session)
        // One-stop receiving: interpretation starts with the summon when
        // signed in (otherwise the login screen shows; RootPanelView re-runs
        // it after the session arrives).
        if authClient.currentSession() != nil {
            session.startInterpretation()
        }
    }

    // MARK: - Vision capture (compose → capturing → legacyVision)

    /// Empty-draft double-tap or the camera button: suspend compose and run
    /// the selection overlay.
    func requestVisionCapture() {
        guard case .compose(let session) = mode else { return }
        guard host?.canCaptureScreen() == true else {
            session.needsScreenCapturePermission = true
            session.errorMessage = "スクリーンショットには画面収録の許可が必要です。"
            return
        }
        session.needsScreenCapturePermission = false
        session.errorMessage = nil
        session.isCapturingScreenshot = true
        mode = .capturing(resume: session)
        host?.beginScreenshotCapture()
    }

    /// Capture flow ended. When the mode has already moved on (double-tap
    /// abandon closed everything), the late outcome is dropped.
    func captureFinished(_ outcome: ScreenCaptureFlowOutcome) {
        guard case .capturing(resume: let session) = mode else { return }
        session.isCapturingScreenshot = false
        switch outcome {
        case .attachment(let attachment):
            session.willEnd()
            let viewModel = makeLegacyVisionViewModel(contextExcluded: session.isContextExcluded)
            mode = .legacyVision(viewModel)
            viewModel.addScreenshotAttachment(attachment)
            host?.applyVisionLayout()
            host?.restorePanelAfterCapture()
        case .cancelled:
            mode = .compose(session)
            host?.restorePanelAfterCapture()
        case .failed(let message):
            session.errorMessage = message
            mode = .compose(session)
            host?.restorePanelAfterCapture()
        }
    }

    /// R1-a bridge: vision/navigator/copilot still run on the legacy view
    /// model. It shares the panel-lifetime deployer (so "承認して送信" pastes
    /// into the summon-time field) and the L1 capture.
    private func makeLegacyVisionViewModel(contextExcluded: Bool) -> ReviewViewModel {
        let deployer = panelContext?.deployer ?? ClipboardDeployer()
        let viewModel = ReviewViewModel(deployer: deployer, mode: .compose)
        if let contextTask = panelContext?.contextTask {
            viewModel.attachContextCapture(contextTask)
        }
        if contextExcluded {
            viewModel.excludeContext()
        }
        viewModel.onExitVisionToCompose = { [weak self] carriedDraft in
            self?.returnToComposeFromVision(carriedDraft: carriedDraft)
        }
        return viewModel
    }

    /// Vision session ended in place (esc from the navigator input, or
    /// "編集する" carrying a draft): back to a compose session in the same panel.
    private func returnToComposeFromVision(carriedDraft: String?) {
        guard case .legacyVision(let viewModel) = mode else { return }
        let deployer = panelContext?.deployer ?? ClipboardDeployer()
        let session = ComposeSession(deployer: deployer)
        session.restorePersistedDraftIfNeeded()
        if let carriedDraft {
            session.draft = carriedDraft
        }
        if let contextTask = panelContext?.contextTask {
            session.attachContextCapture(contextTask)
        }
        if viewModel.isContextExcluded {
            session.excludeContext()
        }
        session.focusedField = .draft
        mode = .compose(session)
        host?.applyTextLayout()
    }

    // MARK: - Dictation (hold-to-talk)

    /// Right-Shift long-press begins: give immediate feedback (sound + red mic)
    /// the instant the gesture is recognized, then start the recorder. The
    /// mic's warm-up adds ~0.5s, but firing the cue first makes it feel snappy.
    func handleHoldBegan() {
        guard !isDictating else { return }
        if case .idle = mode {
            openComposeDirect()
        }
        // Dictation lands wherever there is an editable field: the compose
        // editors and the navigator's question input. The read-only transform
        // pane and the bare vision one-shot have nothing to dictate into.
        guard let target = dictationTarget() else { return }
        isDictating = true
        SoundFeedback.recordingStarted()
        target.errorMessage = nil
        target.isRecording = true
        do {
            try recorder.start()
        } catch {
            target.isRecording = false
            target.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Right-Shift released: stop recording, transcribe, and append the text
    /// to the active field.
    func handleHoldEnded() {
        guard isDictating else { return }
        isDictating = false
        let target = dictationTarget()
        recorder.onFinish = { SoundFeedback.recordingStopped() }
        guard let url = recorder.stop() else { return }
        target?.isRecording = false
        target?.isTranscribing = true
        let transcriber = self.transcriber
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            // Silence gate: drop near-silent or ultra-short clips before the API,
            // since Whisper hallucinates filler on silence. Thresholds are tunable;
            // if the file can't be inspected we fail open and transcribe anyway.
            if let clip = AudioRecorder.inspect(url: url),
               clip.duration < 0.4 || clip.averagePower < -45 {
                await MainActor.run { target?.isTranscribing = false }
                return
            }
            do {
                let text = try await transcriber.transcribe(fileURL: url)
                await MainActor.run {
                    target?.appendTranscription(text)
                    target?.isTranscribing = false
                }
            } catch {
                await MainActor.run {
                    target?.isTranscribing = false
                    target?.errorMessage = "文字起こしに失敗: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
        }
    }

    private func dictationTarget() -> DictationTarget? {
        switch mode {
        case .compose(let session):
            return session
        case .legacyVision(let viewModel):
            return viewModel.navigatorSessionActive ? viewModel : nil
        default:
            return nil
        }
    }
}
