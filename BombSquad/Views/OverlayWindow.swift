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

/// The pointing overlay's window: takes key so Esc and typing work, and gets
/// there without the activation handshake.
///
/// Measured 2026-08-23 (R14 F2): `.nonactivatingPanel` plus `makeKey()` holds
/// key status synchronously, while `NSApp.activate` plus `makeKeyAndOrderFront`
/// — what `ScreenshotSelectionOverlay` does — leaves the window not yet key at
/// the moment it appears, because cooperative activation is asynchronous on
/// macOS 14. For something summoned by a hotkey, where the first click has to
/// land, that decides the construction.
///
/// A panel rather than a window because `.nonactivatingPanel` is only honoured
/// for panels. Placement still goes through `cover(_:)` for the reason written
/// at the top of this file.
final class NonactivatingOverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        isReleasedWhenClosed = false
        // The cursor's position is part of the interface here — the wash keeps
        // a clear core around it — so moved events have to arrive.
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func cover(_ screen: NSScreen) {
        setFrame(screen.frame, display: false)
    }
}
