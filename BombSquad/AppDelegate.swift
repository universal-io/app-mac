import AppKit
import SwiftUI

/// Process-level wiring only: app lifecycle, global inputs, permissions,
/// authentication callbacks, and the on-demand management window.
/// Feature sessions and the floating panel belong to `SessionCoordinator`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var managementWindow: NSWindow?
    private var permissionsWindow: NSWindow?
    private lazy var permissions = PermissionsCoordinator()
    private lazy var authClient = BombSquadAuthClient.shared
    private let gesture = ModifierGestureMonitor()
    private let recorder = AudioRecorder()
    private var coreCoordinator: SessionCoordinator?

    private func trace(
        _ name: StaticString,
        details: [(StaticString, DiagnosticValue)] = []
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.trace(name, details: details)
            }
            return
        }
        MainActor.assumeIsolated {
            Diagnostics.record(
                name,
                mode: coreCoordinator?.stateMachine.mode ?? .idle,
                details: details
            )
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppRuntime.isRunningUnitTests {
            // Hosted unit tests launch the app executable only as a loader.
            // Do not start global event monitors, permission windows, or the
            // single-instance terminator inside the test runner.
            NSApp.setActivationPolicy(.prohibited)
            return
        }
        trace("app.didFinishLaunching")
        terminateOtherRunningCopies()
        ScreenshotCaptureService.cleanupTemporaryCaptures()
        AppSupport.cleanupPendingAccountDeletions()
        AppSupport.removeRetiredMemoryDatabases()
        NSApp.setActivationPolicy(.accessory)

        // Start shared services before the first summon so authentication
        // state does not flash through an uninitialized panel state.
        _ = AuthViewModel.shared
        Task {
            await GatewayAIWarmup.warmAll()
            // The local Supabase session may publish just after launch.
            try? await Task.sleep(for: .seconds(2))
            await GatewayAIWarmup.warmAll()
        }
        SoundFeedback.prepare()

        permissions.onMicrophoneGranted = { [weak self] in self?.recorder.warmUp() }
        permissions.refresh()
        if permissions.needsAny {
            presentPermissionsSetup()
        }

        let coordinator = MainActor.assumeIsolated { SessionCoordinator() }
        coreCoordinator = coordinator
        gesture.onSingleTap = {
            MainActor.assumeIsolated { coordinator.handle(.singleTap) }
        }
        gesture.onDoubleTap = {
            MainActor.assumeIsolated { coordinator.handle(.doubleTap) }
        }
        gesture.onLongPressBegan = {
            MainActor.assumeIsolated { coordinator.handle(.longPressBegan) }
        }
        gesture.onLongPressEnded = {
            MainActor.assumeIsolated { coordinator.handle(.longPressEnded) }
        }
        gesture.start()

        MainActor.assumeIsolated {
            let commandCenter = AppCommandCenter.shared
            commandCenter.onShowManagementRequested = { [weak self] in
                self?.trace("command.showManagement")
                self?.showManagementWindow()
            }
            commandCenter.onScreenshotCaptureRequested = { [weak self] in
                self?.trace("command.captureScreenshot")
                self?.coreCoordinator?.handle(.screenshotCaptureRequested)
            }
            commandCenter.onScreenCaptureSettingsRequested = {
                ScreenCapturePermission.openSettings()
            }
            commandCenter.onProactiveSuggestionSettingChanged = { [weak self] isEnabled in
                self?.coreCoordinator?.setProactiveSuggestionEnabled(isEnabled)
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task {
            try? await authClient.handleIncomingURL(url)
        }
    }

    @objc private func handleResignActive() {
        trace("app.resignActive")

        // Browser and Mail are part of the login flow. Keep the visible auth
        // gate alive until their callback returns to this app.
        guard authClient.currentSession() != nil else {
            trace("app.resignActive.skip", details: [("reason", .literal("auth"))])
            return
        }

        MainActor.assumeIsolated {
            coreCoordinator?.handle(.appResignedActive)
        }
    }

    /// During development, Xcode can leave an older DerivedData build running;
    /// only one process may own the global gesture monitor.
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

    /// Opens the single reusable management window and closes the transient
    /// panel first so the normal window cannot appear behind it.
    private func showManagementWindow() {
        MainActor.assumeIsolated {
            coreCoordinator?.handle(.closeRequested)
        }

        if let managementWindow {
            NSApp.activate(ignoringOtherApps: true)
            managementWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Universal I/O"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ManagementView())
        window.setContentSize(NSSize(width: 820, height: 600))
        window.center()

        managementWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Presents one focused first-run window for all required macOS grants.
    private func presentPermissionsSetup() {
        if let permissionsWindow {
            bringToFront(permissionsWindow)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Universal I/O"
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(
            rootView: PermissionsSetupView(coordinator: permissions) { [weak self] in
                self?.permissionsWindow?.close()
            }
        )
        window.contentViewController = hosting
        // Size to the SwiftUI content so the window is never taller than its
        // rows — otherwise the hardcoded height throws off the centering.
        window.setContentSize(hosting.view.fittingSize)
        // Keep a NORMAL window level. bringToFront() raises it to the front the
        // moment it appears (over a window that happened to be open first), but
        // a permanent floating level would trap the system permission dialogs
        // the grant flow opens *afterward* behind this panel — the user needs
        // those to come in front. fullScreenAuxiliary only lets it show over a
        // full-screen app; it does not force it above later dialogs.
        window.collectionBehavior = [.fullScreenAuxiliary]
        centerOnActiveScreen(window)

        permissionsWindow = window
        // Owned here, not by the view's `.onAppear`. This window's entire job is
        // to notice the moment the user grants a permission in System Settings;
        // if the polling start rode on an appearance callback that never fired,
        // the user would grant access and watch nothing happen — the same shape
        // as the vision stall (docs/reliability-hardening-plan.md D9).
        MainActor.assumeIsolated { permissions.startMonitoring() }
        bringToFront(window)
    }

    /// Activates the app and forces the window to the very front, even when
    /// another app is currently active.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func centerOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }
}
