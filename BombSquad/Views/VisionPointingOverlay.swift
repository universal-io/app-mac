import AppKit
import SwiftUI

/// Vision, on the real screen.
///
/// The panel this replaces put a shrunken screenshot beside a conversation, so
/// the user's eye travelled between the thing they asked about and the answer.
/// Here the screen they are already looking at *is* the picture: a wash goes
/// over it to say "this is for pointing at, not for using", a click anywhere
/// becomes the question, and the answer appears beside the spot.
///
/// The wash also does the work that makes clicking a question possible at all:
/// it swallows the click, so pointing at a button does not press it. That is why
/// the overlay covers the display rather than floating in a corner.
///
/// Nothing here decides anything. It reports where the user pointed and shows
/// what it is handed; the session owns the turn, the coordinator owns the mode.
@MainActor
final class VisionPointingOverlay {
    /// Where the user pointed, in the covered screen's own coordinates
    /// (Cocoa, bottom-left origin).
    var onPoint: ((CGPoint) -> Void)?
    /// Esc, or any other request to leave pointing.
    var onClose: (() -> Void)?

    private var panel: NonactivatingOverlayPanel?
    private var canvas: PointingCanvas?
    private var bubble: NSHostingView<AnyView>?
    private var screenFrame: CGRect = .zero
    /// Kept so the bubble can be re-placed when its own size changes.
    private var placedSize: CGSize = .zero
    private var reflow: Timer?

    var isVisible: Bool { panel?.isVisible == true }
    /// The screen this overlay covers, so a click can be converted against the
    /// same frame the window was placed with.
    var coveredScreenFrame: CGRect { screenFrame }

    func present<Content: View>(on screen: NSScreen, bubble content: Content) {
        close()
        screenFrame = screen.frame

        let panel = NonactivatingOverlayPanel()
        panel.cover(screen)

        let canvas = PointingCanvas(
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )
        canvas.onPoint = { [weak self] point in self?.onPoint?(point) }
        canvas.onClose = { [weak self] in self?.onClose?() }

        // Two siblings rather than "paint the wash, then add a subview": the
        // bubble has to be above the wash, and subview order is the only thing
        // that says so without depending on how AppKit happens to compose a
        // layer-backed view's own drawing against its children.
        let wash = WashView(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.wash = wash
        canvas.addSubview(wash)

        let host = NSHostingView(rootView: AnyView(content))
        host.frame = NSRect(x: 0, y: 0, width: Self.bubbleWidth, height: 1)
        canvas.addSubview(host)

        panel.contentView = canvas
        panel.orderFrontRegardless()
        // Key without activating: see NonactivatingOverlayPanel.
        panel.makeKey()

        self.panel = panel
        self.canvas = canvas
        self.bubble = host
        placeBubble()

        // The bubble grows while an answer streams in, and AppKit does not tell
        // a superview that a hosting view's content got taller. Ten times a
        // second is below noticing, costs a size comparison, and keeps the
        // bubble beside the mark through the whole of an answer arriving.
        reflow = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeBubbleIfResized() }
        }
    }

    /// What the user pointed at, and what the app measured there.
    ///
    /// Both are drawn on the live screen in the same colour, because both mean
    /// "this one". The magenta burned into the image is a different audience —
    /// that one is for the model, and is chosen to be absent from real interface
    /// chrome rather than to look like the product.
    func setMark(point: CGPoint?, frame: CGRect?) {
        canvas?.wash?.mark = point
        canvas?.wash?.hitFrame = frame
        placeBubble()
    }

    func close() {
        reflow?.invalidate()
        reflow = nil
        panel?.orderOut(nil)
        panel = nil
        canvas = nil
        bubble = nil
        placedSize = .zero
    }

    // MARK: - Bubble placement

    /// Fixed width, variable height: a bubble that also changes width while a
    /// sentence arrives reads as the layout thrashing rather than as somebody
    /// speaking. The view inside uses the same constant, so there is one width.
    static let bubbleWidth: CGFloat = 380

    private func placeBubbleIfResized() {
        guard let bubble else { return }
        let height = bubble.fittingSize.height
        guard abs(height - placedSize.height) > 0.5 else { return }
        placeBubble()
    }

    private func placeBubble() {
        guard let bubble, let canvas else { return }
        let size = CGSize(
            width: Self.bubbleWidth,
            height: max(1, bubble.fittingSize.height)
        )
        // Bounds are the visible frame in the covered screen's coordinates, so
        // the bubble clears the menu bar and the Dock without knowing they
        // exist.
        let visible = NSScreen.screens
            .first { $0.frame == screenFrame }?
            .visibleFrame ?? screenFrame
        let bounds = CGRect(
            x: visible.minX - screenFrame.minX,
            y: visible.minY - screenFrame.minY,
            width: visible.width,
            height: visible.height
        )
        let origin = VisionBubblePlacement.origin(
            for: canvas.wash?.mark,
            size: size,
            in: bounds,
            avoid: [canvas.wash?.hitFrame].compactMap { $0 }
        )
        bubble.frame = CGRect(origin: origin, size: size)
        placedSize = size
    }
}

/// Routes the gesture and owns nothing else. The wash draws below it, the bubble
/// above it, and everything the user reads comes from the bubble — a card in the
/// middle of the picture covers the place they are trying to look at, which the
/// web client established the hard way.
private final class PointingCanvas: NSView {
    var onPoint: ((CGPoint) -> Void)?
    var onClose: (() -> Void)?
    weak var wash: WashView?

    override var acceptsFirstResponder: Bool { true }
    /// Without this the first click on a window whose app is not active is spent
    /// activating it and never reaches the view.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        onPoint?(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        wash?.cursor = convert(event.locationInWindow, from: nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onClose?()
            return
        }
        super.keyDown(with: event)
    }

}

/// The wash, the spotlight, the mark and the frame.
///
/// Transparent to the mouse: the container above owns the gesture, and a view
/// that swallowed clicks here would make the point of the whole surface — that a
/// click is a question — depend on which subview happened to be on top.
private final class WashView: NSView {
    var mark: CGPoint? { didSet { needsDisplay = true } }
    var hitFrame: CGRect? { didSet { needsDisplay = true } }
    var cursor: CGPoint? { didSet { needsDisplay = true } }

    /// Colour only, no brightness filter, so the screen underneath keeps its own
    /// light and dark. Shared value with the web client's wash.
    private static let wash = NSColor(srgbRed: 0.29, green: 0.31, blue: 1.0, alpha: 1)
    private static let washAlpha: CGFloat = 0.40
    /// One colour for "here, this, the thing you touched" — the mark and the
    /// frame, and nothing else. State never borrows it.
    private static let iris = NSColor(srgbRed: 0.29, green: 0.31, blue: 1.0, alpha: 1)
    private static let spotlightRadius: CGFloat = 300

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawWash()
        if let hitFrame { draw(frame: hitFrame) }
        if let mark { draw(mark: mark) }
    }

    /// The wash, with a soft hole around the cursor.
    ///
    /// The hole is erased out of the wash with a radial gradient rather than
    /// clipped: a hard-edged circle reads as a cut-out — a hole punched in a
    /// sheet — and the thing it is meant to read as is light. The proportions are
    /// the web client's, arrived at there by trying the alternatives: the inner
    /// half stays completely clear and the whole falloff happens in the outer
    /// half. An even fade from the centre looks like fog, and a narrow core with
    /// a long tail loses its edge entirely.
    ///
    /// Nothing is added to the core — it is left alone. Adding light there was
    /// tried on the web and it fogged the one place the user was trying to read.
    ///
    /// The spotlight follows the cursor for as long as the overlay is up,
    /// including after a question. It says where the pointer is on a screen this
    /// app has covered, and that stays true.
    private func drawWash() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(Self.wash.withAlphaComponent(Self.washAlpha).cgColor)
        context.fill(bounds)

        guard let cursor else { return }
        context.saveGState()
        // Erase rather than paint: `destinationOut` takes the gradient's alpha
        // out of what is already there, which is what makes the edge of the hole
        // as soft as the gradient itself.
        context.setBlendMode(.destinationOut)
        let opaque = NSColor.white.cgColor
        let clear = NSColor.white.withAlphaComponent(0).cgColor
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [opaque, opaque, clear] as CFArray,
            locations: [0, 0.5, 1]
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: cursor,
                startRadius: 0,
                endCenter: cursor,
                endRadius: Self.spotlightRadius,
                options: []
            )
        }
        context.restoreGState()
    }

    /// A ring with a crosshair, never a filled dot: what was pointed at has to
    /// stay visible, or the mark hides the answer's subject.
    private func draw(mark point: CGPoint) {
        let radius: CGFloat = 22
        let tick = radius * 0.4
        // A dark halo rather than a second colour: iris nearly vanishes on a
        // blue app, and adding a colour would promise a second meaning.
        for (color, width) in [
            (NSColor.black.withAlphaComponent(0.45), CGFloat(6)),
            (Self.iris, CGFloat(3)),
        ] {
            color.setStroke()
            let circle = NSBezierPath(ovalIn: CGRect(
                x: point.x - radius, y: point.y - radius,
                width: radius * 2, height: radius * 2
            ))
            circle.lineWidth = width
            circle.stroke()

            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: point.x - tick, y: point.y))
            cross.line(to: CGPoint(x: point.x + tick, y: point.y))
            cross.move(to: CGPoint(x: point.x, y: point.y - tick))
            cross.line(to: CGPoint(x: point.x, y: point.y + tick))
            cross.lineWidth = width
            cross.stroke()
        }
    }

    private func draw(frame rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -4), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 6
        path.stroke()
        Self.iris.setStroke()
        path.lineWidth = 2.5
        path.stroke()
    }
}
