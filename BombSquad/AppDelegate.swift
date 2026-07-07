import AppKit
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
    /// Posted by the legacy view model when a vision session ends and the panel
    /// should return to the narrow single-column layout.
    static let visionSessionEnded = Notification.Name("BombSquad.visionSessionEnded")
    /// Posted from the panel when the user wants to grant screen recording.
    static let openScreenCaptureSettings = Notification.Name("BombSquad.openScreenCaptureSettings")
    /// Posted by the legacy view model when guided navigation (copilot) starts
    /// or ends (`userInfo["active"]: Bool`). While active the panel drops its
    /// modal behavior: it shrinks to a corner strip, survives outside
    /// clicks, and never steals focus from the app being navigated
    /// (docs/navigator-copilot-plan.md 正のユーザー体験).
    static let copilotModeChanged = Notification.Name("BombSquad.copilotModeChanged")
}

/// App lifecycle and window mechanics only (R1-a; redesign plan §7). Gesture
/// semantics, sessions, and mode transitions live in `SessionCoordinator` —
/// this class hosts its window-side effects (`SessionCoordinatorHost`) and
/// still owns the legacy capture overlay plumbing until R1-b.
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
    private var coordinator: SessionCoordinator!
    private let authClient = BombSquadAuthClient.shared
    private let gesture = ShiftGestureMonitor()
    private let screenshotCapture = ScreenshotCaptureService()
    private let screenshotCaptureCue = ScreenshotCaptureCuePresenter()
    private let screenshotSelection = ScreenshotSelectionOverlay()
    /// Guards against overlapping capture flows.
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

        MainActor.assumeIsolated {
            coordinator = SessionCoordinator(host: self)
        }

        // Permissions: one focused setup window that requests Accessibility,
        // Screen Recording, and Microphone deliberately (and registers Screen
        // Recording in the TCC list so it can be toggled after a reset). Shown
        // only when something is missing; otherwise we just warm up audio.
        permissions.onMicrophoneGranted = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.coordinator.warmUpRecorder() }
        }
        permissions.refresh()
        if permissions.needsAny {
            presentPermissionsSetup()
        }

        // Right Shift double-tap = summon → review, or empty text → vision → close.
        // Right Shift long-press = hold-to-talk dictation. ⌘J toggles the panel.
        // All semantics live in the coordinator's transition table.
        HotKeyCenter.shared.onHotKey = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.coordinator.togglePanel() }
        }
        HotKeyCenter.shared.register()
        gesture.onSingleTap = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.coordinator.handleSingleTap() }
        }
        gesture.onDoubleTap = { [weak self] in self?.handleDoubleTapGesture() }
        gesture.onLongPressBegan = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.coordinator.handleHoldBegan() }
        }
        gesture.onLongPressEnded = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.coordinator.handleHoldEnded() }
        }
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

    // MARK: - Gestures that involve the capture overlay (R1-a: owned here)

    /// Double-tap while the capture overlay is up abandons the vision session
    /// entirely: back to the pre-panel standby state. The pending capture task
    /// sees the mode has moved on and stays quiet. Everything else goes to the
    /// coordinator's transition table.
    private func handleDoubleTapGesture() {
        MainActor.assumeIsolated {
            if screenshotSelection.isPresenting {
                screenshotSelection.cancel()
                coordinator.close()
                return
            }
            coordinator.handleDoubleTap()
        }
    }

    // MARK: - Notification handlers (forwarders; NotificationCenter dies in R2)

    @objc private func handleShowPanel() {
        MainActor.assumeIsolated { coordinator.togglePanel() }
    }

    @objc private func handleClosePanel() {
        MainActor.assumeIsolated { coordinator.close() }
    }

    @objc private func handleCaptureScreenshot(_ notification: Notification) {
        MainActor.assumeIsolated { coordinator.requestVisionCapture() }
    }

    @objc private func handleResignActive() {
        guard !isCapturingScreenshot else { return }

        // Guided navigation inverts the modal rule: clicking the target app
        // is the interaction, so losing active is the NORMAL state, never a
        // close signal (docs/navigator-copilot-plan.md 正のユーザー体験 §5).
        guard !isCopilotActive else { return }

        // Login can legitimately move focus to the browser or Mail. Keep the
        // auth gate alive so the user has a visible return point after callback.
        guard authClient.currentSession() != nil else { return }

        // The staging panel is a transient "capture" mode; touching another app's
        // input releases it. Closing on resign makes it behave modally.
        guard panel != nil else { return }
        MainActor.assumeIsolated { coordinator.close() }
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

    /// Legacy path only (bridge exits go through the coordinator, which calls
    /// `applyTextLayout()` directly).
    @objc private func handleVisionSessionEnded() {
        applyTextLayout()
    }

    @objc private func handleOpenScreenCaptureSettings() {
        ScreenCapturePermission.openSettings()
    }

    /// Open (or bring to front) the single management window. The desired section
    /// has already been set on `ManagementNavigator.shared` by the caller.
    ///
    /// The capture panel is an always-on-top floating panel, so any normal window
    /// would open behind it. The panel is transient anyway, so we close it and let
    /// the management window take over (e.g. login → the account/login screen).
    @objc private func handleShowManagement() {
        if panel != nil {
            MainActor.assumeIsolated { coordinator.close() }
        }

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

    // MARK: - Screen geometry helpers

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

// MARK: - SessionCoordinatorHost (window-side effects; all on the main thread)

extension AppDelegate: SessionCoordinatorHost {
    var isPanelVisible: Bool {
        panel?.isVisible ?? false
    }

    func presentPanel() {
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissPanel() {
        isCopilotActive = false
        panel?.orderOut(nil)
        panel = nil
    }

    func canCaptureScreen() -> Bool {
        ScreenCapturePermission.isGranted || ScreenCapturePermission.request()
    }

    /// M4 (owner spec): the selection overlay opens with the whole screen
    /// pre-selected — Enter keeps it, a drag narrows it to a region, Esc
    /// returns to the panel, and a right-Shift double-tap (handled in
    /// `handleDoubleTapGesture`) abandons the session.
    func beginScreenshotCapture() {
        guard !isCapturingScreenshot, let panel else {
            MainActor.assumeIsolated { coordinator.captureFinished(.cancelled) }
            return
        }
        isCapturingScreenshot = true
        panel.orderOut(nil)

        // Resolve "the screen the user is looking at" on the main thread,
        // before hopping into the capture task.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let displayID = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID

        Task {
            let outcome: ScreenCaptureFlowOutcome
            do {
                let attachment = try await captureAttachment(on: screen, displayID: displayID)
                outcome = .attachment(attachment)
            } catch ScreenshotCaptureError.cancelled {
                // Expected: Esc from the selection overlay, an abandoned
                // session, or the system capture UI's cancel.
                outcome = .cancelled
            } catch {
                outcome = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }

            await MainActor.run {
                self.isCapturingScreenshot = false
                self.coordinator.captureFinished(outcome)
            }
        }
    }

    func applyVisionLayout() {
        guard let panel, panel.frame.size.width < Self.visionPanelSize.width else { return }
        panel.setContentSize(Self.visionPanelSize)
        centerOnActiveScreen(panel)
    }

    func applyTextLayout() {
        guard let panel, panel.frame.size.width > Self.textPanelSize.width else { return }
        panel.setContentSize(Self.textPanelSize)
        centerOnActiveScreen(panel)
    }

    func restorePanelAfterCapture() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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

    /// Spotlight-style chrome: borderless transparent window; the SwiftUI
    /// glass shape (PanelChrome) is the visible panel.
    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.textPanelSize.width, height: Self.textPanelSize.height
            ),
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
            rootView: MainActor.assumeIsolated { RootPanelView(coordinator: coordinator) }
        )
        // Enforce a fixed size so SwiftUI can't resize the window out from under
        // the centering math; then center exactly.
        panel.setContentSize(Self.textPanelSize)
        centerOnActiveScreen(panel)
        return panel
    }
}
