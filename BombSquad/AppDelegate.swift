import AppKit
import AVFoundation
import SwiftUI

extension Notification.Name {
    /// Posted by the menu-bar item to summon the panel.
    static let showPanel = Notification.Name("BombSquad.showPanel")
    /// Posted from the panel (Esc) to cancel/close it.
    static let closePanel = Notification.Name("BombSquad.closePanel")
    /// Posted by the menu bar (or the panel's login CTA) to open the on-demand
    /// management window. The target section is set on `ManagementNavigator.shared`
    /// before posting.
    static let showManagement = Notification.Name("BombSquad.showManagement")
    /// Posted from the panel to start a screenshot capture: the selection
    /// overlay opens with the full screen pre-selected (Enter confirms,
    /// dragging picks a region instead).
    static let captureScreenshot = Notification.Name("BombSquad.captureScreenshot")
    /// Hide the panel while an approved action executes: a synthetic click
    /// must land on the TARGET app, not on our own floating panel covering
    /// it. Sessions are single-action for now (the multi-step loop with an
    /// automatic progress re-capture is parked: restoring the panel after a
    /// synthetic click proved unreliable); the failure path restores it.
    static let hidePanelForAction = Notification.Name("BombSquad.hidePanelForAction")
    static let showPanelAfterAction = Notification.Name("BombSquad.showPanelAfterAction")
    /// Posted by the view model when a vision session ends and the panel
    /// should return to the narrow single-column layout.
    static let visionSessionEnded = Notification.Name("BombSquad.visionSessionEnded")
    /// Posted from the panel when the user wants to grant screen recording.
    static let openScreenCaptureSettings = Notification.Name("BombSquad.openScreenCaptureSettings")
    /// Posted by the view model when guided navigation (copilot) starts or
    /// ends (`userInfo["active"]: Bool`). While active the panel drops its
    /// modal behavior: it shrinks to a corner strip, survives outside
    /// clicks, and never steals focus from the app being navigated
    /// (docs/poc-ga-navigator.md あるべきユーザー体験).
    static let copilotModeChanged = Notification.Name("BombSquad.copilotModeChanged")
}

/// Owns the global hotkey and the floating review panel summoned by ⌘J.
/// On hotkey: capture the frontmost app (the paste target), then show a floating
/// panel hosting the staging/review UI wired to a `PasteDeployer`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Text mode is a single Spotlight-style column; vision needs two panes.
    private static let textPanelSize = NSSize(width: 680, height: 660)
    private static let visionPanelSize = NSSize(width: 960, height: 640)
    /// Guided navigation shrinks the panel to a corner strip so the screen
    /// being navigated stays visible and clickable.
    private static let copilotPanelSize = NSSize(width: 460, height: 240)

    private var panel: NSPanel?
    /// The single on-demand management window (account/settings/history/pricing).
    /// Created lazily and reused; never always-on.
    private var managementWindow: NSWindow?
    private var permissionsWindow: NSWindow?
    // Lazy so the @MainActor initializer runs on first use (in
    // applicationDidFinishLaunching), not in a nonisolated property default.
    private lazy var permissions = PermissionsCoordinator()
    private var currentViewModel: ReviewViewModel?
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
    private var isCapturingScreenshot = false
    /// True while guided navigation runs: suspends the panel's modal
    /// close-on-resign behavior (clicking the target app IS the interaction).
    private var isCopilotActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowPanel), name: .showPanel, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleClosePanel), name: .closePanel, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowManagement), name: .showManagement, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleCaptureScreenshot), name: .captureScreenshot, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleHidePanelForAction),
            name: .hidePanelForAction, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowPanelAfterAction),
            name: .showPanelAfterAction, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleVisionSessionEnded), name: .visionSessionEnded, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleCopilotModeChanged), name: .copilotModeChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenScreenCaptureSettings),
            name: .openScreenCaptureSettings, object: nil
        )
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
        guard !isCapturingScreenshot else { return }

        // Guided navigation inverts the modal rule: clicking the target app
        // is the interaction, so losing active is the NORMAL state, never a
        // close signal (docs/poc-ga-navigator.md あるべきユーザー体験 §5).
        guard !isCopilotActive else { return }

        // Login can legitimately move focus to the browser or Mail. Keep the
        // auth gate alive so the user has a visible return point after callback.
        guard authClient.currentSession() != nil else { return }

        // The staging panel is a transient "capture" mode; touching another app's
        // input releases it. Closing on resign makes it behave modally.
        if panel != nil { closePanel() }
    }

    /// Copilot on: shrink to a bottom-right strip that never covers the
    /// navigated screen. Copilot off (task finished or abandoned while the
    /// panel is open): restore the wide vision layout and bring the panel
    /// forward so the final answer is readable.
    @objc private func handleCopilotModeChanged(_ notification: Notification) {
        let active = (notification.userInfo?["active"] as? Bool) ?? false
        isCopilotActive = active
        guard let panel else { return }
        if active {
            panel.setContentSize(Self.copilotPanelSize)
            positionBottomTrailing(panel)
        } else {
            panel.setContentSize(Self.visionPanelSize)
            centerOnActiveScreen(panel)
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
        // Double-tap while the capture overlay is up abandons the vision
        // session entirely: back to the pre-panel standby state. The pending
        // capture task sees the panel is gone and stays quiet.
        let isSelecting = MainActor.assumeIsolated { screenshotSelection.isPresenting }
        if isSelecting {
            MainActor.assumeIsolated { screenshotSelection.cancel() }
            closePanel()
            return
        }
        if panel == nil {
            summon()
            return
        }
        MainActor.assumeIsolated {
            guard let viewModel = currentViewModel else {
                closePanel()
                return
            }

            if viewModel.sessionKind == .vision {
                closePanel()
                return
            }

            guard viewModel.focusedField == .draft else { return }
            if viewModel.isEmptyDraft {
                startScreenshotCapture()
            } else {
                viewModel.requestReviewFromHotkey()
            }
        }
    }

    private func toggleEditorFocus() {
        guard panel != nil else { return }
        MainActor.assumeIsolated {
            guard currentViewModel?.sessionKind == .text else { return }
            currentViewModel?.toggleFocusedField()
        }
    }

    /// Summon the panel. If the frontmost app has a current selection, pull it in
    /// as a received message to transform (receiving side); otherwise open the
    /// empty compose pane (sending side). The selection grab must happen before
    /// our panel steals focus, so it runs here while the target is still front.
    private func summon() {
        SelectionGrabber.grab { [weak self] selection in
            if let selection {
                self?.showPanel(prefill: selection, mode: .transform)
            } else {
                self?.showPanel(mode: .compose)
            }
        }
    }

    /// Right Shift long-press begins: give immediate feedback (sound + red mic) the instant
    /// the gesture is recognized, then start the recorder. The mic's warm-up adds
    /// ~0.5s, but firing the cue first makes it feel snappy; the tiny head clip is
    /// negligible in practice.
    private func startDictation() {
        guard !isDictating else { return }
        if panel == nil { showPanel() }
        let vm = currentViewModel
        // Dictation is available wherever there is an editable field: the text
        // compose/review session, and the navigator's question input. The bare
        // (pre-navigator) vision one-shot has no input to dictate into.
        guard MainActor.assumeIsolated({
            vm?.sessionKind == .text || vm?.navigatorSessionActive == true
        }) else { return }
        isDictating = true
        SoundFeedback.recordingStarted()
        MainActor.assumeIsolated {
            vm?.errorMessage = nil
            vm?.isRecording = true
        }
        do {
            try recorder.start()
        } catch {
            MainActor.assumeIsolated {
                vm?.isRecording = false
                vm?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Right Shift released: stop recording, transcribe, and append the text to the draft.
    private func stopDictationAndTranscribe() {
        guard isDictating else { return }
        isDictating = false
        let vm = currentViewModel
        recorder.onFinish = { SoundFeedback.recordingStopped() }
        guard let url = recorder.stop() else { return }
        MainActor.assumeIsolated {
            vm?.isRecording = false
            vm?.isTranscribing = true
        }
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            // Silence gate: drop near-silent or ultra-short clips before the API,
            // since Whisper hallucinates filler on silence. Thresholds are tunable;
            // if the file can't be inspected we fail open and transcribe anyway.
            if let clip = AudioRecorder.inspect(url: url),
               clip.duration < 0.4 || clip.averagePower < -45 {
                await MainActor.run { vm?.isTranscribing = false }
                return
            }
            do {
                let text = try await transcriber.transcribe(fileURL: url)
                await MainActor.run {
                    vm?.appendTranscription(text)
                    vm?.isTranscribing = false
                }
            } catch {
                await MainActor.run {
                    vm?.isTranscribing = false
                    vm?.errorMessage = "文字起こしに失敗: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
        }
    }

    @objc private func handleShowPanel() {
        togglePanel()
    }

    /// Open (or bring to front) the single management window. The desired section
    /// has already been set on `ManagementNavigator.shared` by the caller.
    ///
    /// The capture panel is an always-on-top floating panel, so any normal window
    /// would open behind it. The panel is transient anyway, so we close it and let
    /// the management window take over (e.g. login → the account/login screen).
    @objc private func handleShowManagement() {
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

    @objc private func handleClosePanel() {
        closePanel()
    }

    @objc private func handleCaptureScreenshot(_ notification: Notification) {
        startScreenshotCapture()
    }

    /// The approved action is about to run: get the panel out of the way so
    /// a synthetic click hits the target app (and the user sees it happen).
    @objc private func handleHidePanelForAction(_ notification: Notification) {
        panel?.orderOut(nil)
    }

    /// The action failed (or no capture follows): restore the panel.
    ///
    /// After a synthetic click the TARGET app is frontmost, and macOS 14's
    /// cooperative activation can silently refuse `NSApp.activate` from a
    /// background app — after which makeKeyAndOrderFront does nothing and
    /// the panel looks "gone". `orderFrontRegardless` bypasses activation
    /// and puts the floating panel back on screen unconditionally.
    @objc private func handleShowPanelAfterAction(_ notification: Notification) {
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
    @objc private func handleVisionSessionEnded() {
        guard let panel, panel.frame.size.width > Self.textPanelSize.width else { return }
        panel.setContentSize(Self.textPanelSize)
        centerOnActiveScreen(panel)
    }

    @objc private func handleOpenScreenCaptureSettings() {
        ScreenCapturePermission.openSettings()
    }

    private func togglePanel() {
        if let panel, panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel(prefill: String? = nil, mode: ReviewMode = .compose) {
        // Capture the target BEFORE our panel activates and steals focus.
        let target = NSWorkspace.shared.frontmostApplication
        // Same timing constraint: identify the context source app now; the AX
        // tree walk itself continues in the background against that pid.
        let contextTask = SituationalContextService.captureTask()
        let deployer: Deployer
        switch mode {
        case .compose:
            deployer = PasteDeployer(targetApp: target) { [weak self] in self?.closePanel() }
        case .transform:
            // Received message: never write back into the sender's field. The
            // readable version is for reading, so "send" only copies to clipboard.
            deployer = ClipboardDeployer()
        }
        let viewModel = MainActor.assumeIsolated {
            ReviewViewModel(deployer: deployer, mode: mode)
        }
        currentViewModel = viewModel
        MainActor.assumeIsolated {
            viewModel.restorePersistedDraftIfNeeded()
            viewModel.attachContextCapture(contextTask)
        }
        if let prefill {
            MainActor.assumeIsolated {
                viewModel.draft = prefill
                // Receiving side: the selection is already captured, so run the
                // transform immediately — the panel opens with the readable
                // result already showing on the right (one stop, no second tap).
                if mode == .transform, authClient.currentSession() != nil {
                    Task { await viewModel.runReview() }
                }
            }
        }

        // Spotlight-style chrome: borderless transparent window; the SwiftUI
        // glass shape (PanelChrome) is the visible panel.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.textPanelSize.width, height: Self.textPanelSize.height),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
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
        panel.contentViewController = NSHostingController(
            rootView: MainActor.assumeIsolated { RootPanelView(reviewViewModel: viewModel) }
        )
        // Enforce a fixed size so SwiftUI can't resize the window out from under
        // the centering math; then center exactly.
        panel.setContentSize(Self.textPanelSize)
        centerOnActiveScreen(panel)

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanel() {
        // Whatever closes the panel, the view model is about to be
        // discarded: save the conversation, stop the copilot click monitor,
        // and take the highlight ring down with it.
        MainActor.assumeIsolated {
            currentViewModel?.panelWillClose()
        }
        isCopilotActive = false
        panel?.orderOut(nil)
        panel = nil
        currentViewModel = nil
    }

    /// M4 (owner spec): summoning on an empty draft opens the selection
    /// overlay with the whole screen pre-selected — Enter keeps it, a drag
    /// narrows it to a region, Esc returns to the panel, and a right-Shift
    /// double-tap (handled in `advance()`) abandons the session.
    private func startScreenshotCapture() {
        guard !isCapturingScreenshot else { return }
        guard let panel, let viewModel = currentViewModel else { return }

        guard ScreenCapturePermission.isGranted || ScreenCapturePermission.request() else {
            MainActor.assumeIsolated {
                viewModel.needsScreenCapturePermission = true
                viewModel.errorMessage = "スクリーンショットには画面収録の許可が必要です。"
            }
            return
        }

        isCapturingScreenshot = true
        MainActor.assumeIsolated {
            viewModel.isCapturingScreenshot = true
            viewModel.needsScreenCapturePermission = false
            viewModel.errorMessage = nil
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
            do {
                let attachment = try await captureAttachment(on: screen, displayID: displayID)
                await MainActor.run {
                    viewModel.addScreenshotAttachment(attachment)
                }
            } catch ScreenshotCaptureError.cancelled {
                // Expected: Esc from the selection overlay, an abandoned
                // session, or the system capture UI's cancel.
            } catch {
                await MainActor.run {
                    viewModel.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }

            await MainActor.run {
                viewModel.isCapturingScreenshot = false
                self.isCapturingScreenshot = false
                guard self.panel === panel else { return }
                // Vision shows two panes (screenshot / interpretation), so give
                // the panel the wide layout before it reappears.
                if viewModel.sessionKind == .vision,
                   panel.frame.size.width < Self.visionPanelSize.width {
                    panel.setContentSize(Self.visionPanelSize)
                    self.centerOnActiveScreen(panel)
                }
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
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
}
