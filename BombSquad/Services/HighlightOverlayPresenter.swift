import AppKit

/// Draws the AI's "here it is" ring on the LIVE screen (POC Step 3): a red
/// rounded rectangle over the real UI element, floating above every window,
/// click-through, and gone after a few seconds. The panel's in-image
/// highlight tells the user where in the picture; this one points at the
/// actual pixels they need to click.
@MainActor
final class HighlightOverlayPresenter {
    static let shared = HighlightOverlayPresenter()

    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Shows the ring around a rect given in global display coordinates
    /// (CG orientation, top-left origin) — the coordinate space of
    /// `ScreenshotAttachment.captureRect`. `duration: nil` keeps the ring up
    /// until the next `show`/`hide` — copilot mode needs the target to stay
    /// marked while the user moves the mouse over to click it.
    func show(around cgRect: CGRect, duration: TimeInterval? = 2.6) {
        hide()

        // CG (top-left origin) → Cocoa global (bottom-left of main display).
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cocoaTarget = CGRect(
            x: cgRect.minX,
            y: mainHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
        // Padding so the ring surrounds rather than covers, plus room for
        // the stroke and glow.
        let margin: CGFloat = 14
        let frame = cocoaTarget.insetBy(dx: -margin, dy: -margin)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = HighlightRingView(frame: NSRect(origin: .zero, size: frame.size))
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }

        self.window = window
        if let duration {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.fadeOutAndHide()
            }
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        window?.orderOut(nil)
        window = nil
    }

    private func fadeOutAndHide() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.45
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.hide() }
        })
    }
}

/// The ring itself: red rounded stroke with a soft glow, matching the
/// in-panel highlight so both read as the same gesture.
private final class HighlightRingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset: CGFloat = 8
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        path.lineWidth = 4

        // Glow pass (wider, translucent) then the crisp ring.
        NSColor.systemRed.withAlphaComponent(0.35).setStroke()
        let glow = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 12, yRadius: 12)
        glow.lineWidth = 9
        glow.stroke()

        NSColor.systemRed.setStroke()
        path.stroke()
    }
}
