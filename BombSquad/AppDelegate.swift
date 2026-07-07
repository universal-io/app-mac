import AppKit
import SwiftUI

/// App lifecycle and the pieces that are genuinely app-global: launch
/// housekeeping, permissions, the management/permissions windows, gesture
/// wiring, and the screenshot capture flow (`ScreenCaptureFlowRunning`).
/// Modes live in `SessionCoordinator`, the panel window in `PanelController`
/// (redesign plan §7 R2) — the three objects form the app's spine.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The single on-demand management window (account/settings/history/pricing).
    /// Created lazily and reused; never always-on.
    private var managementWindow: NSWindow?
    private var permissionsWindow: NSWindow?
    // Lazy so the @MainActor initializer runs on first use (in
    // applicationDidFinishLaunching), not in a nonisolated property default.
    private lazy var permissions = PermissionsCoordinator()
    private var coordinator: SessionCoordinator!
    private var panelController: PanelController!
    private let authClient = BombSquadAuthClient.shared
    private let gesture = ShiftGestureMonitor()
    private let screenshotCapture = ScreenshotCaptureService()
    private let screenshotCaptureCue = ScreenshotCaptureCuePresenter()
    private let screenshotSelection = ScreenshotSelectionOverlay()
    /// Guards against overlapping capture flows.
    private var isCapturingScreenshot = false

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
            coordinator = SessionCoordinator()
            panelController = PanelController()
            panelController.bind(to: coordinator)
            // Presenting the panel must never drag the management window to
            // the front (NSApp.activate raises every window): hide it first.
            panelController.willPresentPanel = { [weak self] in
                self?.hideManagementWindowForPanel()
            }
            panelController.openManagement = { [weak self] in
                self?.openManagementWindow(section: .account)
            }
            coordinator.host = panelController
            coordinator.captureRunner = self
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

        // The one system notification we still observe; every app-internal
        // command travels as a direct call or closure since R2.
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

    // MARK: - Menu-bar entry points

    func togglePanelFromMenu() {
        MainActor.assumeIsolated { coordinator.togglePanel() }
    }

    /// Open (or bring to front) the single management window at a section.
    ///
    /// The capture panel is an always-on-top floating panel, so any normal
    /// window would open behind it. The panel is transient anyway, so we
    /// close it and let the management window take over (e.g. login → the
    /// account/login screen).
    func openManagementWindow(section: ManagementSection) {
        MainActor.assumeIsolated {
            ManagementNavigator.shared.section = section
            if panelController.isPanelVisible { coordinator.close() }
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

    /// Summoning the panel hides a visible management window instead of
    /// dragging it forward with the activation (README: "入力補助のたびに管理
    /// ウィンドウへ勝手にフォーカスを移さない"; the 2026-07-04 bug). The menu
    /// bar reopens it in one click.
    private func hideManagementWindowForPanel() {
        guard let managementWindow, managementWindow.isVisible else { return }
        managementWindow.orderOut(nil)
    }

    // MARK: - Gestures that involve the capture overlay

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

    @objc private func handleResignActive() {
        guard !isCapturingScreenshot else { return }

        // Login can legitimately move focus to the browser or Mail. Keep the
        // auth gate alive so the user has a visible return point after callback.
        guard authClient.currentSession() != nil else { return }

        // The staging panel is a transient "capture" mode; touching another
        // app's input releases it (modal). Whether the current mode is modal
        // is the PanelSpec's contract — copilot and the capture overlay
        // invert the rule (docs/navigator-copilot-plan.md 正のユーザー体験 §5).
        MainActor.assumeIsolated {
            guard panelController.isPanelVisible else { return }
            guard coordinator.shouldCloseOnResignActive else { return }
            coordinator.close()
        }
    }

    // MARK: - Permissions window

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
        PanelController.centerOnActiveScreen(window)

        permissionsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - ScreenCaptureFlowRunning (selection overlay + ScreenCaptureKit)

extension AppDelegate: ScreenCaptureFlowRunning {
    @MainActor func canCaptureScreen() -> Bool {
        ScreenCapturePermission.isGranted || ScreenCapturePermission.request()
    }

    /// M4 (owner spec): the selection overlay opens with the whole screen
    /// pre-selected — Enter keeps it, a drag narrows it to a region, Esc
    /// returns to the panel, and a right-Shift double-tap (handled in
    /// `handleDoubleTapGesture`) abandons the session.
    @MainActor func beginScreenshotCapture() {
        guard !isCapturingScreenshot, panelController.isPanelVisible else {
            coordinator.captureFinished(.cancelled)
            return
        }
        isCapturingScreenshot = true
        panelController.hidePanelForCapture()

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
}
