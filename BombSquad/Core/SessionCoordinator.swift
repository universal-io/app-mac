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
/// Phase 1 introduced the machinery; Phase 3 moved compose, transform,
/// Vision, Navigator, and Copilot here; Phase 4 made it the live path.
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
    private let screenshotSelection = ScreenshotSelectionOverlay()
    private var composeSession: ComposeSession?
    private var transformSession: TransformSession?
    private var visionSession: VisionSession?
    private var summonTargetApp: NSRunningApplication?
    private var isDictating = false
    private var transcriptionTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = 0
    /// Full-screen shot taken silently the moment compose is summoned, so a
    /// later Shift double-tap into Vision reuses it with zero capture latency.
    /// Owned here until it is either handed to a VisionSession (which deletes
    /// it on teardown) or discarded when compose exits without using it.
    private var composePreCapture: ScreenshotAttachment?
    private var composePreCaptureTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var composeGeneration = 0

    init() {
        panelController.onCloseRequested = { [weak self] in
            self?.handle(.closeRequested)
        }
        stateMachine.onTransition = { [weak self] _, next, _ in
            self?.applyPanel(for: next)
        }
        CoreTrace.event("coordinator.started", mode: stateMachine.mode)
    }

    /// Single entry point for all input events.
    func handle(_ event: AppEvent) {
        let mode = stateMachine.mode
        CoreTrace.event("coordinator.event", mode: mode, details: ["event": event.description])
        switch event {
        case .doubleTap:
            handleDoubleTap(in: mode)
        case .menuPanelToggle:
            if mode == .idle {
                summonCompose()
            } else {
                close(reason: "menuPanelToggle")
            }
        case .screenshotCaptureRequested:
            guard mode == .compose else { return }
            beginVisionCaptureFromCompose()
        case .closeRequested:
            close(reason: "closeRequested")
        case .appResignedActive:
            guard let spec = PanelSpec.forMode(mode), spec.closesOnResignActive else { return }
            close(reason: "resignActive")
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
        case .vision, .navigator, .copilot:
            close(reason: "doubleTapOnVision")
        case .compose:
            // The cycle is 閉 → コンポーズ → Vision → 閉: a double-tap always
            // advances compose to Vision. Review is an explicit button, never
            // this gesture. Reuse the silent pre-capture for an instant entry;
            // fall back to the interactive capture when none is ready.
            guard composeSession != nil else { return }
            if !enterVisionReusingPreCapture() {
                beginVisionCaptureFromCompose()
            }
        case .transform:
            close(reason: "doubleTapTransform")
        case .capturing(let returnTo):
            // Abandon the capture session entirely: back to standby.
            _ = returnTo
            close(reason: "doubleTapDuringCapture")
        }
    }

    /// Right-Shift double-tap from idle: if text is selected in the front app,
    /// open the receiving-side transform flow; otherwise open compose.
    private func summonSelectionAware() {
        SelectionGrabber.grab { [weak self] selection in
            Task { @MainActor [weak self] in
                guard let self, self.stateMachine.mode == .idle else { return }
                if let selection {
                    self.presentTransformSession(with: selection)
                } else {
                    self.presentComposeSession()
                }
            }
        }
    }

    /// Idle summon routes that should never inspect the current selection
    /// (menu-bar command, hold-to-talk bootstrap) always open compose.
    private func summonCompose() {
        guard stateMachine.mode == .idle else { return }
        presentComposeSession()
    }

    /// Compose summon captures the paste target and L1 context before the
    /// panel activates and steals focus from the originating app.
    private func presentComposeSession() {
        let target = NSWorkspace.shared.frontmostApplication
        summonTargetApp = target
        let rootContextTask = SituationalContextService.captureTask()
        let deployer = PasteDeployer(targetApp: target) { [weak self] in
            self?.close(reason: "composeDeploy")
        }
        let session = ComposeSession(
            deployer: deployer,
            contextCaptureTask: Task { await rootContextTask.value }
        )
        transformSession?.tearDown()
        transformSession = nil
        visionSession?.tearDown()
        visionSession = nil
        composeSession = session
        guard stateMachine.transition(to: .compose, reason: "summon") else {
            session.tearDown()
            composeSession = nil
            summonTargetApp = nil
            return
        }
        startComposePreCapture()
    }

    /// Transform summon shares the same summon-time context capture, but the
    /// exit is clipboard-only so no target app handle is retained.
    private func presentTransformSession(with selection: String) {
        summonTargetApp = nil
        let rootContextTask = SituationalContextService.captureTask()
        let session = TransformSession(
            receivedText: selection,
            contextCaptureTask: Task { await rootContextTask.value }
        )
        composeSession?.tearDown()
        composeSession = nil
        visionSession?.tearDown()
        visionSession = nil
        transformSession = session
        guard stateMachine.transition(to: .transform, reason: "summonSelection") else {
            session.tearDown()
            transformSession = nil
            return
        }
    }

    private func close(reason: String) {
        guard stateMachine.mode != .idle else { return }
        stopActiveWork()
        discardComposePreCapture()
        stateMachine.transition(to: .idle, reason: reason)
        screenshotSelection.cancel()
        composeSession?.tearDown()
        composeSession = nil
        transformSession?.tearDown()
        transformSession = nil
        visionSession?.tearDown()
        visionSession = nil
        summonTargetApp = nil
    }

    // MARK: - Dictation

    private func startDictation() {
        guard !isDictating else { return }
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
                composeSession.errorMessage =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        case .vision:
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
                visionSession.errorMessage =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        case .navigator, .copilot:
            return
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
        case .vision:
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
                        "文字起こしに失敗: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                case .vision(let session):
                    guard self.visionSession === session else { return }
                    session.isTranscribing = false
                    session.errorMessage =
                        "文字起こしに失敗: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
        }
    }

    private func stopActiveWork() {
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
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
        guard ScreenCapturePermission.isGranted else { return }
        composeGeneration += 1
        let generation = composeGeneration
        composePreCaptureTask = Task { [weak self] in
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let displayID = screen?.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID
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
                }
            }
        }
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
        guard AppSettings.isProactiveSuggestEnabled() else { return }
        guard let composeSession, composeSession.isEmptyDraft else { return }
        guard let client = GatewaySuggestClient.make() else { return }

        let session = composeSession
        let captureID = attachment.id
        suggestionTask?.cancel()
        suggestionTask = Task { [weak self] in
            guard let self else { return }
            let context = await session.awaitSituationalContext()
            // Only spend a model call when an editable field is actually
            // focused. A compose summon with no field focused is likely a
            // transit to Vision — the pre-capture already ran for that.
            guard context?.focusedFieldEditable == true else {
                await MainActor.run {
                    guard self.composeGeneration == generation,
                          self.composeSession === session else { return }
                    self.suggestionTask = nil
                }
                return
            }
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
                    session.applySuggestion(draft: suggestion.draft, note: suggestion.note)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard self.composeGeneration == generation,
                          self.composeSession === session,
                          self.stateMachine.mode == .compose else { return }
                    self.suggestionTask = nil
                    session.markSuggestionUnavailable()
                }
            }
        }
    }

    /// Enter Vision reusing the silent pre-capture, skipping the interactive
    /// overlay entirely. Ownership of the image transfers to the VisionSession.
    /// Returns false when no pre-capture is ready (caller falls back).
    private func enterVisionReusingPreCapture() -> Bool {
        guard let composeSession, let attachment = composePreCapture else { return false }
        composePreCapture = nil
        composePreCaptureTask?.cancel()
        composePreCaptureTask = nil
        guard stateMachine.transition(to: .capturing(returnTo: .compose), reason: "composePreCaptureVision")
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
        guard stateMachine.transition(to: .capturing(returnTo: .compose), reason: "emptyComposeCapture")
        else {
            return
        }

        captureGeneration += 1
        let generation = captureGeneration
        captureTask?.cancel()
        captureTask = Task { [weak self, weak composeSession] in
            guard let self, let composeSession else { return }

            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let displayID = screen?.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID

            let completion: CaptureCompletion
            do {
                let attachment = try await self.captureAttachment(on: screen, displayID: displayID)
                completion = .attachment(attachment)
            } catch ScreenshotCaptureError.cancelled {
                completion = .cancelled
            } catch {
                completion = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.captureGeneration == generation else { return }
                self.captureTask = nil
                self.handleVisionCaptureCompletion(completion, composeSession: composeSession)
            }
        }
    }

    private func handleVisionCaptureCompletion(
        _ completion: CaptureCompletion,
        composeSession: ComposeSession
    ) {
        // Any entry into a VisionSession retires the pending compose suggestion.
        suggestionTask?.cancel()
        suggestionTask = nil
        guard case .capturing(let returnTo) = stateMachine.mode else { return }

        switch completion {
        case .attachment(let attachment):
            let candidateCaptureTask = VisionObservationCaptureService.captureTask(
                preferredPID: summonTargetApp?.processIdentifier,
                attachment: attachment
            )
            let session = VisionSession(
                attachment: attachment,
                preferredTargetPID: summonTargetApp?.processIdentifier,
                candidateCaptureTask: candidateCaptureTask,
                onRequestModeTransition: { [weak self] target, reason in
                    self?.transitionVision(to: target, reason: reason) ?? false
                },
                onRequestPanelClose: { [weak self] in
                    self?.close(reason: "visionRequestedClose")
                }
            )
            visionSession?.tearDown()
            visionSession = session
            guard stateMachine.transition(to: .vision, reason: "captureCompleted") else {
                session.tearDown()
                visionSession = nil
                _ = stateMachine.transition(to: returnTo, reason: "captureTransitionFailed")
                return
            }
        case .cancelled:
            _ = stateMachine.transition(to: returnTo, reason: "captureCancelled")
        case .failed(let message):
            composeSession.errorMessage = message
            _ = stateMachine.transition(to: returnTo, reason: "captureFailed")
        }
    }

    private func transitionVision(to target: AppMode, reason: String) -> Bool {
        guard visionSession != nil else { return false }
        if target == .copilot, stateMachine.mode == .vision {
            guard stateMachine.transition(to: .navigator, reason: "visionGuideReady") else {
                return false
            }
        }
        return stateMachine.transition(to: target, reason: reason)
    }

    private func captureAttachment(
        on screen: NSScreen?,
        displayID: CGDirectDisplayID?
    ) async throws -> ScreenshotAttachment {
        guard let screen else { throw ScreenshotCaptureError.noCaptureTarget }
        let outcome = await screenshotSelection.present(on: screen)
        try? await Task.sleep(nanoseconds: 150_000_000)

        do {
            switch outcome {
            case .cancelled:
                throw ScreenshotCaptureError.cancelled
            case .fullScreen:
                return try await screenshotCapture.captureFullScreen(displayID: displayID)
            case .region(let rect):
                return try await screenshotCapture.captureRegion(rect, displayID: displayID)
            }
        } catch ScreenshotCaptureError.cancelled {
            throw ScreenshotCaptureError.cancelled
        } catch {
            NSLog(
                "Vision capture failed (display=%@ outcome=%@): %@",
                displayID.map(String.init) ?? "nil",
                String(describing: outcome),
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
        if mode.hasPanel {
            if mode == .compose, let composeSession {
                panelController.present(
                    FoundationComposeRootView(session: composeSession),
                    for: mode
                )
            } else if mode == .transform, let transformSession {
                panelController.present(
                    FoundationTransformRootView(session: transformSession),
                    for: mode
                )
            } else if mode == .vision, let visionSession {
                panelController.present(
                    VisionRootView(session: visionSession),
                    for: mode
                )
            } else if panelController.isVisible {
                panelController.applyMode(mode)
            } else {
                panelController.present(
                    CorePanelShellView(stateMachine: stateMachine),
                    for: mode
                )
            }
        } else if case .capturing = mode {
            panelController.hide()
        } else {
            panelController.close()
        }
    }

}

/// Phase 1 placeholder content: proves on device that gestures drive the
/// state machine and the window geometry follows the mode. Replaced mode by
/// mode in Phase 3.
struct CorePanelShellView: View {
    @ObservedObject var stateMachine: AppStateMachine

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("I//O Core shell (Phase 1)")
                .font(.headline)
            Text("mode: \(stateMachine.mode.description)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Right-Shift double-tap or Esc closes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
