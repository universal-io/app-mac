import AppKit
import Foundation
import SwiftUI

/// Guided-navigation session (AppMode.copilot): the panel is a corner strip,
/// the navigated screen is the real UI, and the user's own clicks drive the
/// loop — click the highlighted spot → automatic silent re-capture →
/// verification turn → next step (docs/navigator-copilot-plan.md
/// 正のユーザー体験).
///
/// The conversation itself keeps living in the wrapped `NavigatorSession`
/// (explicit constructor handoff, redesign plan §4-b); this session adds the
/// click monitor, the debounced progress capture, and the strip state.
@MainActor
final class CopilotSession: ObservableObject, SessionLifecycle {
    let navigator: NavigatorSession

    /// True while the automatic progress capture is in flight (between the
    /// user's click and the fresh screenshot hitting the wire).
    @Published private(set) var isChecking = false

    /// Global mouse-up monitor: global monitors only see events in OTHER
    /// apps — which is exactly the definition of "the user acted on the
    /// navigated screen".
    private var clickMonitor: Any?
    private var recaptureTask: Task<Void, Never>?

    init(navigator: NavigatorSession) {
        self.navigator = navigator
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleProgressCheck()
            }
        }
    }

    // MARK: - SessionLifecycle

    /// Tears the copilot apparatus down (monitor, pending check). The
    /// navigator (and its highlight ring) is owned by whoever receives it
    /// next — the coordinator ends it separately when the panel closes.
    func willEnd() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        recaptureTask?.cancel()
        recaptureTask = nil
        isChecking = false
    }

    // MARK: - Progress loop

    /// Debounced: rapid clicks (double-click, mis-click corrections) collapse
    /// into one check, and the target app gets a beat to react first.
    private func scheduleProgressCheck() {
        guard navigator.navigatorActiveTask != nil,
              !navigator.isExecutingNavigatorAction else { return }
        recaptureTask?.cancel()
        recaptureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.performProgressCapture()
        }
    }

    /// Manual fallback on the copilot strip: check progress right now.
    func requestProgressCheck() {
        guard navigator.navigatorActiveTask != nil else { return }
        recaptureTask?.cancel()
        recaptureTask = Task { [weak self] in
            await self?.performProgressCapture()
        }
    }

    private func performProgressCapture() async {
        guard navigator.navigatorActiveTask != nil, !isChecking, !navigator.isNavigating else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let attachment = try await ScreenshotCaptureService()
                .captureFullScreen(displayID: captureDisplayID())
            guard navigator.navigatorActiveTask != nil else { return }
            // Same path as a manual re-capture: appends the capture turn and
            // streams the verification answer.
            navigator.appendCapture(attachment)
        } catch {
            NSLog("[Copilot] auto progress capture failed: %@", String(describing: error))
        }
    }

    /// The display the session is happening on: where the last capture was
    /// taken, falling back to the main display.
    private func captureDisplayID() -> CGDirectDisplayID {
        if let rect = navigator.visionImage?.captureRect {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            for screen in NSScreen.screens {
                if let id = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID,
                   CGDisplayBounds(id).contains(center) {
                    return id
                }
            }
        }
        return CGMainDisplayID()
    }
}
