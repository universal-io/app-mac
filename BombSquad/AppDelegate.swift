import AppKit
import AVFoundation
import SwiftUI

/// Owns the global hotkey and the floating review panel summoned by ⌘J.
/// On hotkey: capture the frontmost app (the paste target), then show a floating
/// panel hosting the staging/review UI wired to a `PasteDeployer`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct ActivePanel {
        let window: KeyablePanel
        let session: PanelSession
    }

    private enum CaptureCompletion {
        case attachment(ScreenshotAttachment)
        case cancelled
        case failed(String)
    }

    private var activePanel: ActivePanel?
    /// The single on-demand management window (account/settings/history/pricing).
    /// Created lazily and reused; never always-on.
    private var managementWindow: NSWindow?
    private var permissionsWindow: NSWindow?
    // Lazy so the @MainActor initializer runs on first use (in
    // applicationDidFinishLaunching), not in a nonisolated property default.
    private lazy var permissions = PermissionsCoordinator()
    private let authClient = BombSquadAuthClient.shared
    private let gesture = ShiftGestureMonitor()
    private let recorder = AudioRecorder()
    /// Resolved per dictation because gateway availability follows sign-in state.
    private var transcriber: any Transcriber { GatewayTranscriber.make() ?? GroqTranscriber() }
    private let screenshotCapture = ScreenshotCaptureService()
    private let screenshotCaptureCue = ScreenshotCaptureCuePresenter()
    private let screenshotSelection = ScreenshotSelectionOverlay()
    /// Guards against duplicate begin/end callbacks so the cues fire exactly once.
    private var isDictating = false
    private var isCapturingScreenshot: Bool {
        MainActor.assumeIsolated { currentSession?.viewModel.isCapturingScreenshot == true }
    }
    private var panel: KeyablePanel? { activePanel?.window }
    private var currentSession: PanelSession? { activePanel?.session }

    @MainActor
    private func withSessionIfCurrent(_ session: PanelSession, _ body: (PanelSession) -> Void) {
        guard currentSession === session else { return }
        body(session)
    }

    private func trace(_ name: String, details: [String: CustomStringConvertible?] = [:]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.trace(name, details: details)
            }
            return
        }
        MainActor.assumeIsolated {
            SessionTrace.event(
                name,
                mode: InferredAppMode.infer(
                    hasPanel: activePanel != nil,
                    session: currentSession,
                    isCapturingScreenshot: isCapturingScreenshot,
                    isSelectionOverlayPresenting: screenshotSelection.isPresenting
                ),
                details: details
            )
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        trace("app.didFinishLaunching")
        terminateOtherRunningCopies()
        // Menu-bar accessory: no Dock icon, no window until summoned.
        NSApp.setActivationPolicy(.accessory)
        // Start the shared auth session subscription now (not on first summon),
        // so the panel never flashes the login screen while it loads.
        _ = AuthViewModel.shared
        // Sync memory cards with the gateway now, and on every future local
        // edit (debounced). No-op until the gateway is configured and the
        // user is signed in.
        Task { await MemorySyncService.shared.start() }
        // Pre-register sound cues so the first one is instant.
        SoundFeedback.prepare()
        // Permissions: one focused setup window that requests Accessibility,
        // Screen Recording, and Microphone deliberately (and registers Screen
        // Recording in the TCC list so it can be toggled after a reset). Shown
        // only when something is missing; otherwise we just warm up audio.
        permissions.onMicrophoneGranted = { [weak self] in self?.recorder.warmUp() }
        permissions.refresh()
        if permissions.needsAny {
            presentPermissionsSetup()
        }
        // Right Shift double-tap = summon → review, or empty text → vision → close.
        // Right Shift long-press = hold-to-talk dictation. ⌘J toggles the panel.
        HotKeyCenter.shared.onHotKey = { [weak self] in self?.togglePanel() }
        HotKeyCenter.shared.register()
        gesture.onSingleTap = { [weak self] in self?.toggleEditorFocus() }
        gesture.onDoubleTap = { [weak self] in self?.advance() }
        gesture.onLongPressBegan = { [weak self] in self?.startDictation() }
        gesture.onLongPressEnded = { [weak self] in self?.stopDictationAndTranscribe() }
        gesture.start()
        MainActor.assumeIsolated {
            let commandCenter = AppCommandCenter.shared
            commandCenter.onShowPanelRequested = { [weak self] in
                self?.trace("command.showPanel")
                self?.togglePanel()
            }
            commandCenter.onShowManagementRequested = { [weak self] in
                self?.trace("command.showManagement")
                self?.showManagementWindow()
            }
            commandCenter.onScreenshotCaptureRequested = { [weak self] in
                self?.trace("command.captureScreenshot")
                self?.startScreenshotCapture()
            }
            commandCenter.onScreenCaptureSettingsRequested = {
                ScreenCapturePermission.openSettings()
            }
        }
        // Modal-like: if focus leaves to another app/form, exit the mode (close).
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleResignActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )
    }

    /// This app owns global keyboard monitoring and a menu-bar presence. During
    /// development, Xcode can leave an older DerivedData build running while a
    /// newer one starts, causing both copies to respond to the same gestures.
    private func terminateOtherRunningCopies() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherApps = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }

        for app in otherApps {
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if !app.isTerminated {
                    app.forceTerminate()
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task {
            try? await authClient.handleIncomingURL(url)
        }
    }

    @objc private func handleResignActive() {
        trace("app.resignActive")
        guard !isCapturingScreenshot else {
            trace("app.resignActive.skip", details: ["reason": "capturing"])
            return
        }

        // Guided navigation inverts the modal rule: clicking the target app
        // is the interaction, so losing active is the NORMAL state, never a
        // close signal (docs/navigator-copilot-plan.md 正のユーザー体験 §5).
        guard MainActor.assumeIsolated({ currentSession?.flowState }) != .copilot else {
            trace("app.resignActive.skip", details: ["reason": "copilot"])
            return
        }

        // Login can legitimately move focus to the browser or Mail. Keep the
        // auth gate alive so the user has a visible return point after callback.
        guard authClient.currentSession() != nil else {
            trace("app.resignActive.skip", details: ["reason": "auth"])
            return
        }

        // The staging panel is a transient "capture" mode; touching another app's
        // input releases it. Closing on resign makes it behave modally.
        if panel != nil {
            trace("app.resignActive.closePanel")
            closePanel()
        }
    }

    /// Copilot on: shrink to a bottom-right strip that never covers the
    /// navigated screen. Copilot off (task finished or abandoned while the
    /// panel is open): restore the wide vision layout and bring the panel
    /// forward so the final answer is readable.
    private func handleCopilotModeChanged(active: Bool) {
        trace("copilot.changed", details: ["active": active])
        guard let activePanel else { return }
        let panel = activePanel.window
        let session = activePanel.session
        let layout = MainActor.assumeIsolated { session.panelLayout }
        applyPanelLayout(layout, to: panel)
        if !active {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Bottom-right corner of the screen the cursor is on, with a margin.
    private func positionBottomTrailing(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let margin: CGFloat = 24
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin
        ))
    }

    /// Right Shift double-tap: closed summons text mode; empty text mode enters
    /// vision capture; vision mode closes; non-empty draft mode reviews.
    /// Invoked from the key-event monitor, which delivers on the main thread.
    private func advance() {
        trace("gesture.doubleTap")
        // Double-tap while the capture overlay is up abandons the vision
        // session entirely: back to the pre-panel standby state. The pending
        // capture task sees the panel is gone and stays quiet.
        let isSelecting = MainActor.assumeIsolated { screenshotSelection.isPresenting }
        if isSelecting {
            trace("gesture.doubleTap.cancelSelection")
            MainActor.assumeIsolated { screenshotSelection.cancel() }
            closePanel()
            return
        }
        if panel == nil {
            trace("gesture.doubleTap.summon")
            summon()
            return
        }
        MainActor.assumeIsolated {
            guard let session = currentSession else {
                trace("gesture.doubleTap.closeNoSession")
                closePanel()
                return
            }

            if session.shouldClosePanelOnHotkeyDoubleTap {
                trace("gesture.doubleTap.closeVision")
                closePanel()
                return
            }

            guard session.viewModel.focusedField == .draft else {
                trace("gesture.doubleTap.ignore", details: ["reason": "focusNotDraft"])
                return
            }
            if session.canStartScreenshotCaptureFromHotkey {
                trace("gesture.doubleTap.startCapture")
                startScreenshotCapture()
            } else {
                trace("gesture.doubleTap.review")
                session.requestReviewFromHotkey()
            }
        }
    }

    private func toggleEditorFocus() {
        trace("gesture.singleTap")
        guard panel != nil else {
            trace("gesture.singleTap.ignore", details: ["reason": "noPanel"])
            return
        }
        MainActor.assumeIsolated {
            guard currentSession?.canToggleEditorFocus == true else {
                trace("gesture.singleTap.ignore", details: ["reason": "notText"])
                return
            }
            currentSession?.toggleEditorFocus()
            trace("gesture.singleTap.toggled", details: ["focused": String(describing: currentSession?.viewModel.focusedField)])
        }
    }

    /// Summon the panel. If the frontmost app has a current selection, pull it in
    /// as a received message to transform (receiving side); otherwise open the
    /// empty compose pane (sending side). The selection grab must happen before
    /// our panel steals focus, so it runs here while the target is still front.
    private func summon() {
        trace("summon.begin")
        SelectionGrabber.grab { [weak self] selection in
            if let selection {
                self?.trace("summon.selection", details: ["characters": selection.count])
                self?.showPanel(prefill: selection, mode: .transform)
            } else {
                self?.trace("summon.noSelection")
                self?.showPanel(mode: .compose)
            }
        }
    }

    /// Right Shift long-press begins: give immediate feedback (sound + red mic) the instant
    /// the gesture is recognized, then start the recorder. The mic's warm-up adds
    /// ~0.5s, but firing the cue first makes it feel snappy; the tiny head clip is
    /// negligible in practice.
    private func startDictation() {
        trace("dictation.begin")
        guard !isDictating else { return }
        if panel == nil {
            trace("dictation.showPanel")
            showPanel()
        }
        // Dictation is available wherever there is an editable field: the text
        // compose/review session, and the navigator's question input. The bare
        // (pre-navigator) vision one-shot has no input to dictate into.
        guard let session = MainActor.assumeIsolated({ currentSession }),
              MainActor.assumeIsolated({ session.canAcceptDictation }) else {
            trace("dictation.begin.ignore", details: ["reason": "noEditableTarget"])
            return
        }
        isDictating = true
        SoundFeedback.recordingStarted()
        MainActor.assumeIsolated {
            session.viewModel.errorMessage = nil
            session.viewModel.isRecording = true
        }
        do {
            try recorder.start()
            trace("dictation.recordingStarted")
        } catch {
            isDictating = false
            MainActor.assumeIsolated {
                session.viewModel.isRecording = false
                session.viewModel.errorMessage =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            trace("dictation.recordingFailed", details: ["error": error.localizedDescription])
        }
    }

    /// Right Shift released: stop recording, transcribe, and append the text to the draft.
    private func stopDictationAndTranscribe() {
        trace("dictation.end")
        guard isDictating else { return }
        isDictating = false
        recorder.onFinish = { SoundFeedback.recordingStopped() }
        guard let url = recorder.stop() else {
            trace("dictation.end.noFile")
            return
        }
        guard let session = MainActor.assumeIsolated({ currentSession }) else { return }
        MainActor.assumeIsolated {
            session.viewModel.isRecording = false
            session.viewModel.isTranscribing = true
        }
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            // Silence gate: drop near-silent or ultra-short clips before the API,
            // since Whisper hallucinates filler on silence. Thresholds are tunable;
            // if the file can't be inspected we fail open and transcribe anyway.
            if let clip = AudioRecorder.inspect(url: url),
               clip.duration < 0.4 || clip.averagePower < -45 {
                await MainActor.run {
                    self.withSessionIfCurrent(session) { session in
                        session.viewModel.isTranscribing = false
                    }
                }
                await MainActor.run {
                    trace("dictation.droppedSilence", details: [
                        "duration": String(format: "%.2f", clip.duration),
                        "power": String(format: "%.1f", clip.averagePower)
                    ])
                }
                return
            }
            do {
                let text = try await transcriber.transcribe(fileURL: url)
                await MainActor.run {
                    self.withSessionIfCurrent(session) { session in
                        session.viewModel.appendTranscription(text)
                        session.viewModel.isTranscribing = false
                        trace("dictation.transcribed", details: ["characters": text.count])
                    }
                }
            } catch {
                await MainActor.run {
                    self.withSessionIfCurrent(session) { session in
                        session.viewModel.isTranscribing = false
                        session.viewModel.errorMessage =
                            "文字起こしに失敗: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                        trace("dictation.transcribeFailed", details: ["error": error.localizedDescription])
                    }
                }
            }
        }
    }

    /// Open (or bring to front) the single management window. The desired section
    /// has already been set on `ManagementNavigator.shared` by the caller.
    ///
    /// The capture panel is an always-on-top floating panel, so any normal window
    /// would open behind it. The panel is transient anyway, so we close it and let
    /// the management window take over (e.g. login → the account/login screen).
    private func showManagementWindow() {
        if panel != nil { closePanel() }

        if let managementWindow {
            NSApp.activate(ignoringOtherApps: true)
            managementWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Universal I/O"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.contentViewController = NSHostingController(rootView: ManagementView())
        window.setContentSize(NSSize(width: 820, height: 600))
        window.center()

        managementWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// First-run permission setup. A real key window (unlike the menu-bar
    /// accessory alone) keeps the system permission prompts on the active
    /// screen instead of scattering them across displays.
    private func presentPermissionsSetup() {
        if let permissionsWindow {
            NSApp.activate(ignoringOtherApps: true)
            permissionsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Universal I/O"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: PermissionsSetupView(coordinator: permissions) { [weak self] in
                self?.permissionsWindow?.close()
            }
        )
        // Put the window on the display the user is actually looking at, so the
        // system permission dialogs land on the same screen.
        centerOnActiveScreen(window)

        permissionsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The approved action is about to run: get the panel out of the way so
    /// a synthetic click hits the target app (and the user sees it happen).
    private func hidePanelForAction() {
        trace("panel.hideForAction")
        panel?.orderOut(nil)
    }

    /// The action failed (or no capture follows): restore the panel.
    ///
    /// After a synthetic click the TARGET app is frontmost, and macOS 14's
    /// cooperative activation can silently refuse `NSApp.activate` from a
    /// background app — after which makeKeyAndOrderFront does nothing and
    /// the panel looks "gone". `orderFrontRegardless` bypasses activation
    /// and puts the floating panel back on screen unconditionally.
    private func showPanelAfterAction() {
        trace("panel.showAfterAction")
        guard let panel else {
            NSLog("[Action] restore skipped: panel is nil")
            return
        }
        NSLog("[Action] restoring panel (visible=%d)", panel.isVisible ? 1 : 0)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// Vision's two-pane session ended (e.g. an action draft was carried into
    /// the compose editor): restore the narrow Spotlight-style layout.
    private func handleVisionSessionEnded() {
        trace("vision.sessionEnded")
        guard let activePanel else { return }
        let panel = activePanel.window
        let session = activePanel.session
        let layout = MainActor.assumeIsolated { session.panelLayout }
        guard panel.frame.size != NSSize(width: layout.size.width, height: layout.size.height)
            || layout.placement != .centered else { return }
        applyPanelLayout(layout, to: panel)
    }

    private func togglePanel() {
        trace("panel.toggle", details: ["visible": panel?.isVisible == true])
        if let panel, panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    @MainActor
    private func makePanelSession(viewModel: ReviewViewModel) -> PanelSession {
        PanelSession(
            viewModel: viewModel,
            callbacks: PanelSessionCallbacks(
                onVisionModeExited: { [weak self] in
                    self?.handleVisionSessionEnded()
                },
                onHidePanelForAction: { [weak self] in
                    self?.hidePanelForAction()
                },
                onShowPanelAfterAction: { [weak self] in
                    self?.showPanelAfterAction()
                },
                onClosePanelRequested: { [weak self] in
                    self?.closePanel()
                },
                onScreenshotCaptureRequested: { [weak self] in
                    self?.startScreenshotCapture()
                },
                onScreenCaptureSettingsRequested: {
                    ScreenCapturePermission.openSettings()
                },
                onCopilotModeChanged: { [weak self] active in
                    self?.handleCopilotModeChanged(active: active)
                }
            )
        )
    }

    private func makeDeployer(for mode: ReviewMode, target: NSRunningApplication?) -> Deployer {
        switch mode {
        case .compose:
            return PasteDeployer(targetApp: target) { [weak self] in self?.closePanel() }
        case .transform:
            // Received message: never write back into the sender's field. The
            // readable version is for reading, so "send" only copies to clipboard.
            return ClipboardDeployer()
        }
    }

    @MainActor
    private func makePanelWindow(for session: PanelSession) -> KeyablePanel {
        let initialLayout = session.panelLayout
        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: initialLayout.size.width,
                height: initialLayout.size.height
            ),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        panel.onCloseRequested = { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.trace("panel.escape")
            self.closePanel()
        }
        panel.title = "Universal I/O"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Never move the window from arbitrary drags: dragging must belong to
        // the content (text selection, image pan, annotation rectangles). The
        // header rows expose an explicit drag handle (WindowDragHandle),
        // matching standard macOS/iOS behavior of "grab the title area".
        panel.isMovableByWindowBackground = false
        panel.contentViewController = NSHostingController(rootView: RootPanelView(session: session))
        applyPanelLayout(initialLayout, to: panel)
        return panel
    }

    private func presentPanel(_ panel: KeyablePanel, session: PanelSession) {
        activePanel = ActivePanel(window: panel, session: session)
        revealPanel(panel)
    }

    private func revealPanel(_ panel: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private func handleCaptureCompletion(
        _ completion: CaptureCompletion,
        session: PanelSession,
        panel: KeyablePanel
    ) {
        switch completion {
        case .attachment(let attachment):
            session.handleCapturedScreenshot(attachment)
            trace("capture.attachmentAdded", details: [
                "width": attachment.pixelWidth,
                "height": attachment.pixelHeight
            ])
            session.finishScreenshotCapture()
            guard self.panel === panel else { return }
            applyPanelLayout(session.panelLayout, to: panel)
            revealPanel(panel)
            trace("capture.end")
        case .cancelled:
            trace("capture.cancelled")
            session.finishScreenshotCapture()
            guard self.panel === panel else { return }
            closePanel()
        case .failed(let message):
            session.failScreenshotCapture(message: message)
            trace("capture.failed", details: ["error": message])
            session.finishScreenshotCapture()
            guard self.panel === panel else { return }
            revealPanel(panel)
            trace("capture.end")
        }
    }

    private func showPanel(prefill: String? = nil, mode: ReviewMode = .compose) {
        trace("panel.show.begin", details: [
            "requestedMode": String(describing: mode),
            "prefillCharacters": prefill?.count
        ])
        // Capture the target BEFORE our panel activates and steals focus.
        let target = NSWorkspace.shared.frontmostApplication
        // Same timing constraint: identify the context source app now; the AX
        // tree walk itself continues in the background against that pid.
        let contextTask = SituationalContextService.captureTask()
        let deployer = makeDeployer(for: mode, target: target)
        let viewModel = MainActor.assumeIsolated {
            ReviewViewModel(deployer: deployer, mode: mode)
        }
        let session = MainActor.assumeIsolated {
            makePanelSession(viewModel: viewModel)
        }
        MainActor.assumeIsolated {
            session.prepareForPresentation(contextTask: contextTask)
        }
        if let prefill {
            MainActor.assumeIsolated {
                // Receiving side: the selection is already captured, so run the
                // transform immediately — the panel opens with the readable
                // result already showing on the right (one stop, no second tap).
                session.applyPrefill(prefill, autoReviewIfAuthenticated: authClient.currentSession() != nil)
            }
        }
        let panel = MainActor.assumeIsolated { makePanelWindow(for: session) }
        presentPanel(panel, session: session)
        trace("panel.show.end", details: ["requestedMode": String(describing: mode)])
    }

    private func closePanel() {
        trace("panel.close.begin")
        // Whatever closes the panel, the view model is about to be
        // discarded: save the conversation, stop the copilot click monitor,
        // and take the highlight ring down with it.
        MainActor.assumeIsolated {
            currentSession?.handlePanelWillClose()
        }
        panel?.onCloseRequested = nil
        panel?.orderOut(nil)
        activePanel = nil
        trace("panel.close.end")
    }

    /// M4 (owner spec): summoning on an empty draft opens the selection
    /// overlay with the whole screen pre-selected — Enter keeps it, a drag
    /// narrows it to a region, Esc closes the session, and a right-Shift
    /// double-tap (handled in `advance()`) abandons the session.
    private func startScreenshotCapture() {
        trace("capture.begin")
        guard !isCapturingScreenshot else { return }
        guard let activePanel else {
            trace("capture.begin.ignore", details: ["reason": "missingPanelOrViewModel"])
            return
        }
        let panel = activePanel.window
        let session = activePanel.session

        guard ScreenCapturePermission.isGranted || ScreenCapturePermission.request() else {
            MainActor.assumeIsolated {
                session.markScreenCapturePermissionRequired(true)
                session.failScreenshotCapture(message: "スクリーンショットには画面収録の許可が必要です。")
            }
            trace("capture.permissionDenied")
            return
        }

        MainActor.assumeIsolated {
            session.beginScreenshotCapture()
        }

        panel.orderOut(nil)

        // Resolve "the screen the user is looking at" on the main thread,
        // before hopping into the capture task.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let displayID = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID

        Task {
            let completion: CaptureCompletion
            do {
                let attachment = try await captureAttachment(on: screen, displayID: displayID)
                completion = .attachment(attachment)
            } catch ScreenshotCaptureError.cancelled {
                // Expected: Esc from the selection overlay, an abandoned
                // session, or the system capture UI's cancel.
                completion = .cancelled
            } catch {
                completion = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }

            await MainActor.run {
                self.handleCaptureCompletion(completion, session: session, panel: panel)
            }
        }
    }

    /// Run the selection overlay, then capture what it chose. When
    /// ScreenCaptureKit fails (permission edge cases), fall back to the
    /// system range-selection UI rather than dead-ending the flow.
    private func captureAttachment(
        on screen: NSScreen?,
        displayID: CGDirectDisplayID?
    ) async throws -> ScreenshotAttachment {
        guard let screen else { throw ScreenshotCaptureError.noCaptureTarget }
        let outcome = await screenshotSelection.present(on: screen)
        // Let the compositor drop the overlay before the shot is taken.
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
            await screenshotCaptureCue.showBriefly()
            return try await screenshotCapture.captureInteractive()
        }
    }

    /// Center the panel on whichever screen the cursor is on, so it never spills
    /// off-screen (e.g. Gmail's right-side compose box).
    private func centerOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        window.setFrameOrigin(origin)
    }

    private func applyPanelLayout(_ layout: PanelLayoutSpec, to window: NSWindow) {
        window.setContentSize(NSSize(width: layout.size.width, height: layout.size.height))
        switch layout.placement {
        case .centered:
            centerOnActiveScreen(window)
        case .bottomTrailing:
            positionBottomTrailing(window)
        }
    }
}
