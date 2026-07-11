import AppKit
import SwiftUI

/// The window's shape as a pure function of `AppMode`.
/// One place decides size, placement, and activation behavior — the legacy
/// path spreads this across AppDelegate and PanelSession.
struct PanelSpec: Equatable {
    enum Placement: Equatable {
        /// Centered on the screen the cursor is on.
        case centered
        /// Bottom-right corner strip (copilot: never cover the navigated screen).
        case bottomTrailing
    }

    let size: CGSize
    let placement: Placement
    /// Whether losing app-active should close the panel in this mode.
    /// Copilot inverts the modal rule: clicking the target app IS the
    /// interaction (docs/navigator-copilot-plan.md 正のユーザー体験 §5).
    let closesOnResignActive: Bool

    static func forMode(_ mode: AppMode) -> PanelSpec? {
        switch mode {
        case .idle, .capturing:
            return nil
        case .compose, .transform:
            return PanelSpec(
                size: CGSize(width: 680, height: 660),
                placement: .centered,
                closesOnResignActive: true
            )
        case .vision, .navigator:
            return PanelSpec(
                size: CGSize(width: 960, height: 640),
                placement: .centered,
                closesOnResignActive: true
            )
        case .copilot:
            return PanelSpec(
                size: CGSize(width: 460, height: 240),
                placement: .bottomTrailing,
                closesOnResignActive: false
            )
        }
    }
}

/// Owns the floating panel window: creation, layout, reveal/hide/close.
/// The coordinator tells it *which mode* the app is in; this class is the
/// only place that translates mode → window geometry and activation calls.
@MainActor
final class PanelController {
    private var panel: KeyablePanel?
    private var appliedSpec: PanelSpec?

    /// Esc (or any in-window close request). The coordinator decides what
    /// closing means in the current mode.
    var onCloseRequested: (() -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the panel with the given SwiftUI content, shaped for `mode`.
    /// Reuses the existing window when one is up (content swap + relayout).
    func present<Content: View>(_ content: Content, for mode: AppMode) {
        guard let spec = PanelSpec.forMode(mode) else { return }
        let panel = self.panel ?? makePanel()
        panel.contentViewController = NSHostingController(rootView: content)
        apply(spec, to: panel)
        self.panel = panel
        reveal(panel, activating: true)
    }

    /// Re-applies geometry after a mode change without touching the content
    /// (the SwiftUI root observes the state machine and re-renders itself).
    func applyMode(_ mode: AppMode, activate: Bool = false) {
        guard let panel, let spec = PanelSpec.forMode(mode) else { return }
        guard spec != appliedSpec else { return }
        apply(spec, to: panel)
        if activate {
            reveal(panel, activating: true)
        }
    }

    /// Temporarily removes the panel from screen (capture, approved actions)
    /// without tearing the session down.
    func hide() {
        panel?.orderOut(nil)
    }

    /// Restores a hidden panel. After a synthetic click the TARGET app is
    /// frontmost, and macOS 14's cooperative activation can silently refuse
    /// `NSApp.activate` from a background app — `orderFrontRegardless`
    /// bypasses activation and puts the floating panel back unconditionally.
    func revealAfterAction() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// Tears the window down. Idempotent.
    func close() {
        panel?.onCloseRequested = nil
        panel?.orderOut(nil)
        panel = nil
        appliedSpec = nil
    }

    // MARK: - Window construction

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 660),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        panel.onCloseRequested = { [weak self] in
            self?.onCloseRequested?()
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
        // Dragging belongs to the content (text selection, image pan);
        // header rows expose an explicit drag handle instead.
        panel.isMovableByWindowBackground = false
        return panel
    }

    private func reveal(_ panel: NSWindow, activating: Bool) {
        if activating {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func apply(_ spec: PanelSpec, to window: NSWindow) {
        window.setContentSize(spec.size)
        switch spec.placement {
        case .centered:
            centerOnActiveScreen(window)
        case .bottomTrailing:
            positionBottomTrailing(window)
        }
        appliedSpec = spec
    }

    /// Center on whichever screen the cursor is on, so the panel never
    /// spills off-screen.
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
}
