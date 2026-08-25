import AppKit

/// Draws guidance's "here it is" on the LIVE screen: a mark over the real UI
/// element, floating above every window, click-through, and gone after a few
/// seconds.
///
/// It draws `MarkStyle`, the same thing the pointing overlay draws. It used to
/// be its own red rounded rectangle with its own corner radius and its own
/// glow, from before pointing existed — so the product had two ways of saying
/// "this one" and a user who met both in a session had no reason to think they
/// were related. Guidance is the surface that most needs the beat: it is asking
/// somebody to find a control and move a mouse to it, which is exactly the wait
/// a still mark has to survive.
@MainActor
final class HighlightOverlayPresenter {
    static let shared = HighlightOverlayPresenter()

    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?
    private var interactionMonitors: [Any] = []

    private init() {}

    /// Shows the ring around a rect given in global display coordinates
    /// (CG orientation, top-left origin) — the coordinate space of
    /// `ScreenshotAttachment.captureRect`. `duration: nil` keeps the ring up
    /// until the next `show`/`hide` — copilot mode needs the target to stay
    /// marked while the user moves the mouse over to click it.
    func show(
        around cgRect: CGRect,
        duration: TimeInterval? = 2.6,
        padding: CGFloat = MarkStyle.outerReach
    ) {
        hide()

        // CG (top-left origin) → Cocoa global (bottom-left of main display).
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cocoaTarget = CGRect(
            x: cgRect.minX,
            y: mainHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
        // Padding so the mark surrounds rather than covers, plus the room the
        // beat needs — a window sized to the element clips it, and the beat is
        // the part that carries across a screen.
        let frame = cocoaTarget.insetBy(dx: -padding, dy: -padding)

        let window = OverlayWindow(clickThrough: true)
        window.place(globalFrame: frame)
        window.contentView = MarkHostView(
            frame: NSRect(origin: .zero, size: frame.size),
            // Back to the element's own rect, in the window's coordinates: the
            // mark adds its own outset, so handing it the padded frame would
            // draw it one padding too far out.
            target: NSRect(origin: .zero, size: frame.size)
                .insetBy(dx: padding, dy: padding)
        )
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }

        self.window = window
        installInteractionDismissMonitors()
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
        removeInteractionMonitors()
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

    private func installInteractionDismissMonitors() {
        removeInteractionMonitors()

        let masks: [NSEvent.EventTypeMask] = [
            [.scrollWheel],
            [.leftMouseDown],
            [.rightMouseDown],
            [.otherMouseDown],
            [.keyDown],
        ]

        for mask in masks {
            if let monitor = NSEvent.addGlobalMonitorForEvents(
                matching: mask,
                handler: { [weak self] _ in
                Task { @MainActor in self?.hide() }
                }
            ) {
                interactionMonitors.append(monitor)
            }
        }
    }

    private func removeInteractionMonitors() {
        for monitor in interactionMonitors {
            NSEvent.removeMonitor(monitor)
        }
        interactionMonitors.removeAll()
    }
}

/// Holds one `MarkStyle` mark and nothing else. Every colour, width, corner and
/// beat comes from there, so this window and the pointing overlay cannot drift.
private final class MarkHostView: NSView {
    init(frame frameRect: NSRect, target: CGRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(MarkStyle.layer(for: .frame(target)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
