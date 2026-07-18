import AppKit

/// The single definition of a transparent screen overlay window (selection
/// overlay, capture cue, live highlight ring). Placement goes through
/// `cover(_:)` / `place(globalFrame:)` ONLY — never pass a screen to
/// NSWindow's initializer: its contentRect-is-relative-to-that-screen
/// semantics produced the same secondary-display offset bug twice before
/// this class existed. `setFrame` takes unambiguous global coordinates.
class OverlayWindow: NSWindow {
    init(clickThrough: Bool) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = clickThrough
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        isReleasedWhenClosed = false
    }

    /// Covers exactly one screen, wherever it sits in the arrangement.
    func cover(_ screen: NSScreen) {
        setFrame(screen.frame, display: false)
    }

    /// Places the window at a global Cocoa frame (bottom-left origin).
    func place(globalFrame: NSRect) {
        setFrame(globalFrame, display: false)
    }
}

/// Overlay that can take key status (the selection overlay needs Enter/Esc).
final class KeyableOverlayWindow: OverlayWindow {
    override var canBecomeKey: Bool { true }
}
