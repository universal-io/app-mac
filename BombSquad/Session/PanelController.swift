import AppKit
import Combine
import SwiftUI

/// Owns the floating panel window and keeps it in the shape the current mode
/// demands (redesign plan §4-d). Window sizing, placement, and every
/// `NSApp.activate` for the panel live HERE and nowhere else — the
/// coordinator decides what mode the app is in, this class makes the window
/// follow.
@MainActor
final class PanelController: SessionCoordinatorHost {
    private var panel: KeyablePanel?
    private var appliedSpec: PanelSpec?
    private var modeCancellable: AnyCancellable?
    private weak var coordinator: SessionCoordinator?

    /// Called just before the panel comes forward. The app delegate hides
    /// the management window here so `NSApp.activate` cannot drag it in
    /// front of the user's work (the 2026-07-04 focus-stealing bug).
    var willPresentPanel: (() -> Void)?
    /// Opens the management window at the account section (login CTA inside
    /// the panel). The management window belongs to the app delegate.
    var openManagement: (() -> Void)?

    func bind(to coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        // Apply the window shape the moment the mode changes — BEFORE SwiftUI
        // swaps the mode's view in. Resizing after the view change reads as
        // flicker (redesign plan §4-d).
        modeCancellable = coordinator.$mode.sink { [weak self] mode in
            self?.apply(mode.panelSpec)
        }
    }

    private func apply(_ spec: PanelSpec?) {
        guard let panel, let spec, spec != appliedSpec else { return }
        appliedSpec = spec
        panel.setContentSize(spec.size)
        position(panel, spec.placement)
    }

    private func position(_ window: NSWindow, _ placement: PanelSpec.Placement) {
        switch placement {
        case .centered:
            Self.centerOnActiveScreen(window)
        case .bottomTrailing:
            Self.positionBottomTrailing(window)
        }
    }

    // MARK: - SessionCoordinatorHost

    var isPanelVisible: Bool {
        panel?.isVisible ?? false
    }

    func presentPanel() {
        willPresentPanel?()
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
        appliedSpec = nil
    }

    /// Out of the way for the capture overlay (window survives, hidden).
    func hidePanelForCapture() {
        panel?.orderOut(nil)
    }

    /// Re-front the (hidden) panel after a capture flow or a copilot exit.
    func restorePanel() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// The approved action is about to run: get the panel out of the way so
    /// a synthetic click hits the target app (and the user sees it happen).
    func hidePanelForAction() {
        panel?.orderOut(nil)
    }

    /// The action failed (or no capture follows): restore the panel.
    ///
    /// After a synthetic click the TARGET app is frontmost, and macOS 14's
    /// cooperative activation can silently refuse `NSApp.activate` from a
    /// background app — after which makeKeyAndOrderFront does nothing and
    /// the panel looks "gone". `orderFrontRegardless` bypasses activation
    /// and puts the floating panel back on screen unconditionally.
    func showPanelAfterAction() {
        guard let panel else {
            NSLog("[Action] restore skipped: panel is nil")
            return
        }
        NSLog("[Action] restoring panel (visible=%d)", panel.isVisible ? 1 : 0)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    // MARK: - Window construction

    /// Spotlight-style chrome: borderless transparent window; the SwiftUI
    /// glass shape (PanelChrome) is the visible panel.
    private func makePanel() -> KeyablePanel? {
        guard let coordinator else { return nil }
        let spec = coordinator.mode.panelSpec ?? .text
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: spec.size.width, height: spec.size.height),
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
        // Esc anywhere in the panel (outside the editors, which handle it
        // themselves) closes it — borderless windows have no close button.
        panel.onCancel = { [weak coordinator] in
            coordinator?.close()
        }
        panel.contentViewController = NSHostingController(
            rootView: RootPanelView(
                coordinator: coordinator,
                onOpenManagement: { [weak self] in self?.openManagement?() }
            )
        )
        // Enforce a fixed size so SwiftUI can't resize the window out from
        // under the placement math; then place exactly.
        panel.setContentSize(spec.size)
        position(panel, spec.placement)
        appliedSpec = spec
        return panel
    }

    // MARK: - Screen geometry (shared with the app delegate's windows)

    /// Center on whichever screen the cursor is on, so the window never
    /// spills off-screen (e.g. Gmail's right-side compose box).
    nonisolated static func centerOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        window.setFrameOrigin(origin)
    }

    /// Bottom-right corner of the screen the cursor is on, with a margin.
    nonisolated static func positionBottomTrailing(_ window: NSWindow) {
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
}
