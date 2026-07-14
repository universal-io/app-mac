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
            guard let composeSession else { return }
            // A double-tap belongs to the draft editor only.
            guard composeSession.focusedField == .draft else { return }
            if composeSession.isEmptyDraft {
                beginVisionCaptureFromCompose()
            } else {
                composeSession.requestReview()
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
        case .vision, .navigator, .copilot:
            guard let visionSession else { return }
            guard visionSession.isNavigatorAvailable else { return }
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
            case navigator(VisionSession)
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
        case .vision, .navigator, .copilot:
            if let visionSession {
                visionSession.isRecording = false
                visionSession.isTranscribing = true
                sink = .navigator(visionSession)
            } else {
                sink = nil
            }
        default:
            sink = nil
        }
        guard let sink else { return }

        OperationalNoticeCenter.shared.beginOperation()
        let transcriber: any Transcriber
        if let gateway = GatewayTranscriber.make() {
            transcriber = gateway
        } else {
            OperationalNoticeCenter.shared.publish(
                code: "CLIENT_PROVIDER_FALLBACK",
                message: "I//O Cloudにアクセスできなかったため、端末のGroq音声認識で処理します。"
            )
            transcriber = GroqTranscriber()
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
                case .navigator(let visionSession):
                    if self.visionSession === visionSession {
                        visionSession.isTranscribing = false
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
                case .navigator(let visionSession):
                    guard self.visionSession === visionSession,
                          self.stateMachine.mode == .vision
                            || self.stateMachine.mode == .navigator
                            || self.stateMachine.mode == .copilot
                    else { return }
                    visionSession.appendTranscription(text)
                    visionSession.isTranscribing = false
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
                case .navigator(let visionSession):
                    guard self.visionSession === visionSession else { return }
                    visionSession.isTranscribing = false
                    visionSession.errorMessage =
                        "文字起こしに失敗: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
        }
    }

    private func stopActiveWork() {
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
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

    // MARK: - Vision capture

    private func beginVisionCaptureFromCompose() {
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
        guard case .capturing(let returnTo) = stateMachine.mode else { return }

        switch completion {
        case .attachment(let attachment):
            let deployer = PasteDeployer(targetApp: summonTargetApp) { [weak self] in
                self?.close(reason: "visionDeploy")
            }
            let session = VisionSession(
                attachment: attachment,
                deployer: deployer,
                contextCaptureTask: composeSession.inheritedContextCaptureTask(),
                fallbackTargetPID: summonTargetApp?.processIdentifier,
                onRequestModeTransition: { [weak self] mode, reason in
                    self?.requestModeTransition(mode, reason: reason)
                },
                onRequestPanelClose: { [weak self] in
                    self?.close(reason: "visionRequestedClose")
                },
                onHidePanelForAction: { [weak self] in
                    self?.panelController.hide()
                },
                onShowPanelAfterAction: { [weak self] in
                    self?.panelController.revealAfterAction()
                }
            ) { [weak self] text in
                self?.returnVisionDraftToCompose(text)
            }
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

    private func returnVisionDraftToCompose(_ text: String) {
        guard let composeSession else { return }
        composeSession.adoptSuggestedDraft(text)
        visionSession?.tearDown()
        visionSession = nil
        _ = stateMachine.transition(to: .compose, reason: "visionEditAction")
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
            } else if (mode == .vision || mode == .navigator || mode == .copilot), let visionSession {
                panelController.present(
                    FoundationVisionRootView(session: visionSession, mode: mode),
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

    private func requestModeTransition(_ mode: AppMode, reason: String) {
        guard stateMachine.mode != mode else { return }
        _ = stateMachine.transition(to: mode, reason: reason)
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
