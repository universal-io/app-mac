import AppKit
import SwiftUI

/// What each mode needs from the app-active rule.
///
/// This used to also carry window size and placement; the compose bubble sizes
/// itself to its content and sits beside the summoning field, so geometry left
/// (2026-08-27). What remains is the one question every mode still has to
/// answer: does losing app-active end the session?
struct PanelSpec: Equatable {
    /// Whether losing app-active should close the panel in this mode.
    /// Copilot inverts the modal rule: clicking the target app IS the
    /// interaction (docs/navigator-copilot-plan.md 正のユーザー体験 §5).
    let closesOnResignActive: Bool

    /// The rule is about the overlay, not about which surface is running.
    ///
    /// Vision used to answer "never close on resign" from its name alone, which
    /// was right only because Vision always covered the screen. A selection
    /// summon does not: the user pointed by selecting, so there is nothing to
    /// point at and no overlay is presented. A bubble that looks like Compose
    /// and appears like Compose has to leave like Compose — staying behind when
    /// every other bare bubble goes away reads as the app failing to notice it
    /// was done (owner decision 2026-09-01, accepting that a long explanation
    /// cannot be scrolled while working in the app underneath).
    ///
    /// While the overlay IS presented the answer stays no, wash or no wash:
    /// measured 2026-08-23, another application can hold frontmost while every
    /// click on the covered display still arrives here, and under guidance
    /// clicking the app being guided IS the interaction (R15).
    static func forMode(_ mode: AppMode, overlayIsPresented: Bool) -> PanelSpec? {
        switch mode {
        case .idle, .capturing:
            return nil
        case .compose:
            return PanelSpec(closesOnResignActive: true)
        case .vision, .copilot:
            return PanelSpec(closesOnResignActive: !overlayIsPresented)
        }
    }
}

/// Owns the compose bubble's window: creation, placement, reveal/hide/close.
///
/// The window is the same card Vision's bubble is — fixed width, height from
/// the content, placed beside its subject — but where Vision's subject is the
/// place the user pointed, Compose's is the field they were writing into when
/// they summoned it. Unlike Vision's bubble it activates the app and takes
/// key normally: Compose exists to be typed into, and losing app-active is
/// still what closes it.
@MainActor
final class PanelController {
    private var panel: KeyablePanel?
    private var host: NSHostingView<AnyView>?
    /// Where the bubble goes: beside the summoning field (`frame`), or where
    /// the user dragged it (`userTopLeft`), which wins until the next summon.
    /// Same one-value rule as Vision's bubble — see `BubbleAnchor`.
    private var anchor = BubbleAnchor()
    private var placedSize: CGSize = .zero
    private var reflow: Timer?
    private var moveObserver: Any?
    /// True while `place()` is setting the frame, so the move it causes is not
    /// mistaken for the user dragging the bubble there.
    private var isPlacing = false

    /// Esc (or any in-window close request). The coordinator decides what
    /// closing means in the current mode.
    var onCloseRequested: (() -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the compose bubble with the given SwiftUI content.
    ///
    /// - Parameter anchorFrame: the summoning field's frame in global Cocoa
    ///   coordinates, or nil when no field is known (menu-bar summon,
    ///   hold-to-talk, an AX read that yielded nothing) — then the bubble opens
    ///   at the centre of the working screen, where the panel it replaces did.
    ///
    /// Reuses the existing window when one is up (content swap + replace); a
    /// window still alive from this same session keeps the place the user gave
    /// it, so a capture round-trip does not shove the card back.
    func present<Content: View>(_ content: Content, anchorFrame: CGRect?) {
        let isNewWindow = panel == nil
        let panel = self.panel ?? makePanel()
        self.panel = panel

        if let host {
            host.rootView = AnyView(content)
        } else {
            let host = NSHostingView(rootView: AnyView(content))
            // The SwiftUI view's own ideal size, kept current as the content
            // changes — same measurement Vision's bubble settled on.
            host.sizingOptions = [.intrinsicContentSize]
            host.frame = NSRect(
                x: 0, y: 0,
                width: VisionPointingOverlay.bubbleWidth, height: 1
            )
            panel.contentView = host
            self.host = host
        }

        if isNewWindow || anchor.frame != anchorFrame {
            anchor = BubbleAnchor(frame: anchorFrame)
        }
        place()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startWatching(panel)
    }

    /// Temporarily removes the panel from screen (capture, approved actions)
    /// without tearing the session down.
    func hide() {
        panel?.orderOut(nil)
    }

    /// Tears the window down. Idempotent.
    func close() {
        reflow?.invalidate()
        reflow = nil
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel?.onCloseRequested = nil
        panel?.orderOut(nil)
        panel = nil
        host = nil
        anchor = BubbleAnchor()
        placedSize = .zero
    }

    // MARK: - Window construction

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: VisionPointingOverlay.bubbleWidth, height: 1
            ),
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
        // AppKit's shadow, cast from the card's own alpha — the view draws
        // none, for the reason written on `BubbleChrome`.
        panel.hasShadow = true
        // The bubble's own drag handle covers everything that is not a control,
        // and this keeps any padding it misses draggable too.
        panel.isMovableByWindowBackground = true
        return panel
    }

    // MARK: - Placement

    /// The taller of the two answers AppKit will give, plus a point for the
    /// final line's descender — same measurement as Vision's bubble.
    private static func height(of host: NSView) -> CGFloat {
        max(host.intrinsicContentSize.height, host.fittingSize.height) + 1
    }

    /// Where the compose bubble goes, as a pure rule so a test can hold the
    /// window to it: beside the summoning field, at the centre of the working
    /// screen when none was measured — where the panel this replaces opened —
    /// and wherever the user dragged it, which wins until the next summon.
    nonisolated static func bubbleOrigin(
        for anchor: BubbleAnchor,
        size: CGSize,
        in bounds: CGRect
    ) -> CGPoint {
        if anchor.frame == nil, anchor.userTopLeft == nil {
            return CGPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            )
        }
        return VisionBubblePlacement.origin(for: anchor, size: size, in: bounds)
    }

    private func place() {
        guard let panel, let host else { return }
        let size = CGSize(
            width: VisionPointingOverlay.bubbleWidth,
            height: max(1, Self.height(of: host))
        )
        // The screen the user is working on — the one showing the app they
        // summoned us from, not the one the pointer happens to rest on.
        guard let bounds = ActiveDisplay.screen()?.visibleFrame
            ?? NSScreen.main?.visibleFrame else { return }

        let origin = Self.bubbleOrigin(for: anchor, size: size, in: bounds)

        isPlacing = true
        defer { isPlacing = false }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        // The shadow is cast from the window's own alpha, and a borderless
        // window keeps the shape it had before the resize until told.
        panel.invalidateShadow()
        host.frame = CGRect(origin: .zero, size: size)
        placedSize = size
    }

    private func startWatching(_ panel: KeyablePanel) {
        // Any movement of the window this class did not perform is the user
        // dragging it: the drag handle asks AppKit to move the window, and the
        // placement finds out from AppKit.
        if moveObserver == nil {
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteMoved() }
            }
        }
        // The bubble grows as a result surface appears or a field wraps, and
        // AppKit does not tell a window that a hosting view's content got
        // taller. Same cadence as Vision's bubble.
        if reflow == nil {
            reflow = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeIfResized() }
            }
        }
    }

    private func placeIfResized() {
        guard let panel, panel.isVisible, let host else { return }
        guard abs(Self.height(of: host) - placedSize.height) > 0.5 else { return }
        place()
    }

    private func noteMoved() {
        guard !isPlacing, let panel else { return }
        anchor.userTopLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }
}
