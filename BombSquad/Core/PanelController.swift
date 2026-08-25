import AppKit
import SwiftUI

/// The window's shape as a pure function of `AppMode`.
/// One place decides size, placement, and activation behavior.
struct PanelSpec: Equatable {
    enum Placement: Equatable {
        /// Centered on the screen the user is working on (`ActiveDisplay`).
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
        case .compose:
            return PanelSpec(
                size: CGSize(width: 680, height: 660),
                placement: .centered,
                closesOnResignActive: true
            )
        case .vision:
            // Vision no longer draws in this window — it puts a wash over the
            // real screen (R14) — but this spec still answers "does losing
            // app-active end the session", and for pointing the answer has to
            // be no. Measured 2026-08-23: another application can hold
            // frontmost while every click on the covered display still arrives
            // here, so a session that closed on resign-active would end itself
            // while the user was still pointing at things.
            return PanelSpec(
                size: CGSize(width: 960, height: 640),
                placement: .centered,
                closesOnResignActive: false
            )
        case .copilot:
            // No panel either: guidance is the pointing overlay with the wash
            // lifted (R15). The spec still answers the resign-active question,
            // and clicking the app being guided IS the interaction, so no.
            return PanelSpec(
                size: CGSize(width: 960, height: 640),
                placement: .centered,
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

    private static let compactComposeSize = CGSize(width: 680, height: 420)
    private static let expandedComposeSize = CGSize(width: 680, height: 660)

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

    /// Compose reserves no empty result area. It grows downward only after a
    /// suggestion/review surface has content worth showing.
    func setComposeExpanded(_ expanded: Bool) {
        guard let panel else { return }
        let contentSize = expanded
            ? Self.expandedComposeSize
            : Self.compactComposeSize
        let currentFrame = panel.frame
        var targetFrame = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        )
        targetFrame.origin.x = currentFrame.midX - targetFrame.width / 2
        targetFrame.origin.y = currentFrame.maxY - targetFrame.height
        guard currentFrame != targetFrame else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            panel.animator().setFrame(targetFrame, display: true)
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
        // Every summon still starts centered, but after presentation the user
        // can drag from any non-interactive background/padding. Editors,
        // buttons, and screenshot tools keep their own pointer handling, while
        // result headers continue to provide an explicit generous drag target.
        panel.isMovableByWindowBackground = true
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

    /// Center on the screen the user is working on — the one showing the app
    /// they summoned us from, not the one the pointer happens to rest on.
    private func centerOnActiveScreen(_ window: NSWindow) {
        guard let visible = ActiveDisplay.screen()?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }

    /// Bottom-right corner of the working screen, with a margin.
    private func positionBottomTrailing(_ window: NSWindow) {
        guard let visible = ActiveDisplay.screen()?.visibleFrame else { return }
        let margin: CGFloat = 24
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin
        ))
    }
}
