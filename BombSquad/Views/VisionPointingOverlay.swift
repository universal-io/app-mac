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
    /// The path the user drew around something, same coordinates. A ring around
    /// several things is how somebody asks about a group they have no name for,
    /// so it arrives as its own gesture rather than as a click at its centre.
    var onRegion: (([CGPoint]) -> Void)?
    /// Esc, or any other request to leave pointing.
    var onClose: (() -> Void)?

    private var panel: NonactivatingOverlayPanel?
    private var canvas: PointingCanvas?
    private var bubble: NSHostingView<AnyView>?
    private var screenFrame: CGRect = .zero
    /// Where the bubble is anchored, which outlives the drawn mark: once the
    /// answer's own frame is up the mark retracts, but the bubble keeps a place
    /// on the picture rather than retreating to the corner.
    private var anchor: CGPoint?
    /// A rectangle the bubble sits beside rather than a point it sits below.
    ///
    /// Two things claim it. The frame the answer pointed at: the words and the
    /// frame are one claim about one element, and showing them in two places —
    /// the frame on the answer's subject, the words beside the click — reads as
    /// the product disagreeing with itself. And the area the user enclosed: a
    /// bubble placed against the middle of a ring covers what the ring was
    /// drawn around, so it goes outside the edge (`app-web/docs/pointing.md`
    /// §2.2).
    private var frameAnchor: CGRect?
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
        // The canvas reports the path it collected; what that path meant is
        // geometry, decided in one place beside the other conversions.
        canvas.onPath = { [weak self] path in
            guard let self else { return }
            switch VisionPointerResolver.gesture(from: path) {
            case .point(let point): onPoint?(point)
            case .region(let drawn): onRegion?(drawn)
            case nil: break
            }
        }
        // Drawn while the hand is still moving, so the line appears under the
        // cursor rather than after the gesture ends.
        canvas.onPathChanged = { [weak self] path in self?.showStroke(path) }
        canvas.onClose = { [weak self] in self?.onClose?() }

        // Two siblings rather than "paint the wash, then add a subview": the
        // bubble has to be above the wash, and subview order is the only thing
        // that says so without depending on how AppKit happens to compose a
        // layer-backed view's own drawing against its children.
        let wash = WashView(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.wash = wash
        canvas.addSubview(wash)

        let host = NSHostingView(rootView: AnyView(content))
        // Report the SwiftUI view's own ideal size and keep reporting it as the
        // content changes. Without this the only measurement available is
        // `fittingSize` against whatever frame the view happens to have, which
        // under-measured by about a line: the last row of an answer came out cut
        // in half horizontally, which looks like a rendering fault rather than a
        // sizing one.
        host.sizingOptions = [.intrinsicContentSize]
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
    /// Both mean "this one", and only one of them is shown at a time. The ring
    /// answers "was my click heard" and is all there is until the element is
    /// known; the moment a measured frame exists it says the same thing more
    /// precisely — around the whole element rather than at a pixel inside it —
    /// so the ring retracts. Drawing both puts a ring on top of a frame it sits
    /// inside, which reads as two marks disagreeing rather than one becoming
    /// certain. Same rule as the answer's frame: what survives is the mark
    /// carrying the newer information.
    ///
    /// The magenta burned into the image is a different audience — that one is
    /// for the model, and is chosen to be absent from real interface chrome
    /// rather than to look like the product.
    func setMark(point: CGPoint?, frame: CGRect?) {
        anchor = point
        // A new gesture starts a new subject: whatever the previous answer
        // pointed at no longer decides where this answer appears, and a line
        // drawn for the previous question is not part of this one.
        frameAnchor = nil
        canvas?.wash?.stroke = nil
        canvas?.wash?.markShape = frame.map(WashView.MarkShape.frame)
            ?? Self.drawnMark(point: point, frame: frame).map(WashView.MarkShape.ring)
        canvas?.wash?.hitFrame = frame
        placeBubble()
    }

    /// Which of the two marks is drawn. A rule with no failure mode of its own —
    /// nothing throws when both appear, it just looks like the product is
    /// pointing at two things — so it is pinned here rather than left to the
    /// next edit of `setMark`.
    nonisolated static func drawnMark(point: CGPoint?, frame: CGRect?) -> CGPoint? {
        frame == nil ? point : nil
    }

    /// The line as it is being drawn.
    ///
    /// Always drawn, even while a previous answer's frame is still up: the line
    /// is the *next* question, not the leftovers of the last one
    /// (`app-web/docs/pointing.md` §3). The frame it replaces belonged to an
    /// answer about somewhere else.
    func showStroke(_ path: [CGPoint]) {
        canvas?.wash?.markShape = nil
        canvas?.wash?.stroke = path
        canvas?.wash?.hitFrame = nil
    }

    /// The finished enclosure stays on screen: it is the only thing saying what
    /// the question was about, and unlike a tap it cannot be re-stated by a
    /// measured frame — accessibility measures elements, and a ring is drawn
    /// around whatever the user could not name.
    ///
    /// The bubble goes outside its edge rather than beside its centre, so it
    /// cannot cover the thing the ring was drawn around.
    func setRegion(path: [CGPoint]) {
        anchor = nil
        frameAnchor = VisionPointerResolver.bounds(of: path)
        canvas?.wash?.markShape = nil
        canvas?.wash?.stroke = path
        canvas?.wash?.hitFrame = nil
        placeBubble()
    }

    /// The answer has pointed at something, so the user's own mark steps back.
    ///
    /// Two marks in almost the same place stop reading as two marks: the web
    /// client found they merge into one smear. The one that survives is the one
    /// carrying new information — where the answer says to look — and the
    /// gesture's own mark has said everything it had to say by then.
    func showAnswerFrame(_ frame: CGRect) {
        canvas?.wash?.markShape = .frame(frame)
        canvas?.wash?.stroke = nil
        canvas?.wash?.hitFrame = frame
        // The bubble follows the frame: from here on the words sit beside the
        // element they are about, which is not always the one under the click.
        frameAnchor = frame
        placeBubble()
    }

    func close() {
        anchor = nil
        frameAnchor = nil
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
        guard abs(Self.height(of: bubble) - placedSize.height) > 0.5 else { return }
        placeBubble()
    }

    /// The taller of the two answers AppKit will give, plus a point.
    ///
    /// `intrinsicContentSize` is the SwiftUI view's own ideal height and is the
    /// one to trust; `fittingSize` is kept as a floor because a hosting view can
    /// report an intrinsic size of zero before its first layout. The extra point
    /// is for the descender of the final line, which was being clipped — text
    /// sliced through the middle reads as a broken renderer, and a point of
    /// unused space reads as nothing at all.
    private static func height(of host: NSView) -> CGFloat {
        max(host.intrinsicContentSize.height, host.fittingSize.height) + 1
    }

    private func placeBubble() {
        guard let bubble, let canvas else { return }
        let size = CGSize(
            width: Self.bubbleWidth,
            height: max(1, Self.height(of: bubble))
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
        let origin: CGPoint
        if let frameAnchor {
            origin = VisionBubblePlacement.origin(
                besideFrame: frameAnchor,
                size: size,
                in: bounds
            )
        } else {
            origin = VisionBubblePlacement.origin(
                for: anchor,
                size: size,
                in: bounds,
                avoid: [canvas.wash?.hitFrame].compactMap { $0 }
            )
        }
        bubble.frame = CGRect(origin: origin, size: size)
        placedSize = size
    }
}

/// Routes the gesture and owns nothing else. The wash draws below it, the bubble
/// above it, and everything the user reads comes from the bubble — a card in the
/// middle of the picture covers the place they are trying to look at, which the
/// web client established the hard way.
private final class PointingCanvas: NSView {
    /// The finished path, from the press to the release. One point when the
    /// hand stayed put — what it meant is not decided here.
    var onPath: (([CGPoint]) -> Void)?
    /// The same path while it is still being drawn.
    var onPathChanged: (([CGPoint]) -> Void)?
    var onClose: (() -> Void)?
    weak var wash: WashView?

    /// Collected in the covered screen's coordinates, in the order drawn.
    private var path: [CGPoint] = []

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

    /// Nothing is decided or drawn on the press.
    ///
    /// A press that turns into a stroke is one gesture about one place, so
    /// firing at the press would spend a request on the point where a ring
    /// happened to start — and every request costs the user a unit. Drawing the
    /// ring here has the same problem in the other direction: on every drag the
    /// user saw a ring flash and then turn into a line, which shows them the
    /// product guessing at a gesture they had not finished making. The press
    /// only starts collecting the path; what it meant is known on release, and
    /// the press-to-release of an ordinary click is too short to read as a
    /// screen that did nothing.
    override func mouseDown(with event: NSEvent) {
        path = [convert(event.locationInWindow, from: nil)]
    }

    override func mouseDragged(with event: NSEvent) {
        guard !path.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        path.append(point)
        // The spotlight follows the hand while it draws; without this it stays
        // where the press began and the line is drawn in the dark.
        wash?.cursor = point
        onPathChanged?(path)
    }

    override func mouseUp(with event: NSEvent) {
        guard !path.isEmpty else { return }
        let finished = path
        path = []
        onPath?(finished)
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
    /// The one thing that says "this one".
    ///
    /// A ring at a point until the element is measured, then the element's own
    /// frame — two shapes of the same object, so they are one type with one
    /// drawing. They used to be two: a hand-drawn ring with a 3pt line and a
    /// target cross, and a layer-drawn frame with a 2.5pt line and a beat. Two
    /// marks that mean the same thing and do not look alike read as two
    /// different features, and the cross in the middle claimed a precision the
    /// mark does not have — the click is not a crosshair, it is a place.
    enum MarkShape {
        case ring(CGPoint)
        case frame(CGRect)

        /// The stroked outline, and — as `spread` grows — what a beat radiates
        /// out to. Radiating a fixed distance rather than scaling: a frame can
        /// be a button or an 800-point toolbar, and doubling the second one
        /// throws a ring across half the screen.
        func path(spread: CGFloat) -> NSBezierPath {
            switch self {
            case .ring(let centre):
                let radius = WashView.ringRadius + spread
                return NSBezierPath(ovalIn: CGRect(
                    x: centre.x - radius, y: centre.y - radius,
                    width: radius * 2, height: radius * 2
                ))
            case .frame(let rect):
                return NSBezierPath(
                    roundedRect: rect.insetBy(dx: -4 - spread, dy: -4 - spread),
                    xRadius: 8 + spread,
                    yRadius: 8 + spread
                )
            }
        }
    }

    /// The ring's radius, which is also what the bubble's placement has to clear.
    static let ringRadius: CGFloat = 22
    /// The line every mark is drawn with, and the dark halo under it. Iris
    /// nearly vanishes on a blue app, and a second colour would promise a
    /// second meaning.
    private static let markLineWidth: CGFloat = 2.5
    private static let markHaloWidth: CGFloat = 6
    /// How far a beat travels before it is gone.
    private static let markBeatSpread: CGFloat = 14

    var markShape: MarkShape? { didSet { renderMark() } }
    /// The line the user drew, in this view's coordinates.
    var stroke: [CGPoint]? { didSet { needsDisplay = true } }
    var hitFrame: CGRect? { didSet { needsDisplay = true } }
    var cursor: CGPoint? { didSet { needsDisplay = true } }

    /// The tint. Colour only — nothing here filters brightness, so the screen
    /// underneath keeps its own light and shade exactly. Raising the alpha to
    /// make it "more purple" is the trap: a flat colour drags dark screens and
    /// light screens alike toward its own lightness, and the web client measured
    /// the difference between them shrinking by a third when that was tried.
    /// Same value as the web client's wash (`app/wash.ts`).
    private static let tint = NSColor(srgbRed: 74 / 255, green: 80 / 255, blue: 1, alpha: 0.40)
    /// One colour for "here, this, the thing you touched" — the mark and the
    /// frame, and nothing else. State never borrows it.
    private static let iris = NSColor(srgbRed: 74 / 255, green: 80 / 255, blue: 1, alpha: 1)

    /// Where the spotlight's falloff ends — not where the clear part ends. The
    /// held-clear core is half of it and every stop of the ramp is a fraction of
    /// it, so this one number resizes the whole light in proportion.
    private static let spotlightReach: CGFloat = 672

    /// The lattice: white dots on a 22-point grid.
    ///
    /// This is the layer that says the screen is being read rather than used.
    /// The wash alone changes the colour; the dots give it a reason — a sensor
    /// looking at a surface. The gap between "I am operating this screen" and "I
    /// am pointing at it" has to be large, because a user who thinks they are
    /// operating it will click a button and get an explanation instead.
    ///
    /// Kept just above the threshold of notice: it should be found, not seen.
    /// Built once as a tile and drawn as a pattern — a few thousand circles
    /// redrawn on every cursor move would be paid for on every frame.
    private static let lattice: NSColor = {
        let side: CGFloat = 22
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16).setFill()
        NSBezierPath(ovalIn: CGRect(x: side / 2 - 1, y: side / 2 - 1, width: 2, height: 2)).fill()
        image.unlockFocus()
        return NSColor(patternImage: image)
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var markLayer: CALayer?

    /// Draws whichever mark is current: dark halo, iris outline, and a beat
    /// radiating out of it.
    ///
    /// One implementation for the ring and the frame, because they are the same
    /// statement — "this one" — and a user who sees them side by side across two
    /// gestures should not be able to tell that two pieces of code drew them.
    ///
    /// A rest between beats is what makes it a beat. A pulse with no gap is a
    /// waiting spinner, which would say something about processing rather than
    /// about a place. Held still under Reduce Motion.
    private func renderMark() {
        // One container so a new mark replaces the old one whole; loose
        // sublayers are how a stale ring outlives the gesture it belonged to.
        markLayer?.removeFromSuperlayer()
        markLayer = nil
        guard let markShape, let host = layer else { return }

        let container = CALayer()
        host.addSublayer(container)
        markLayer = container

        let outline = markShape.path(spread: 0)
        container.addSublayer(Self.stroked(outline, NSColor.black.withAlphaComponent(0.45), Self.markHaloWidth))
        container.addSublayer(Self.stroked(outline, Self.iris, Self.markLineWidth))

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let spread = markShape.path(spread: Self.markBeatSpread)
        let grow = CAKeyframeAnimation(keyPath: "path")
        grow.values = [outline.cgPath, spread.cgPath, spread.cgPath]
        grow.keyTimes = [0, 0.58, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.61, 0, 0]
        fade.keyTimes = [0, 0.58, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.8
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let beat = Self.stroked(outline, Self.iris, Self.markLineWidth)
        beat.add(group, forKey: "beat")
        container.addSublayer(beat)
    }

    private static func stroked(
        _ path: NSBezierPath,
        _ color: NSColor,
        _ width: CGFloat
    ) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path.cgPath
        layer.fillColor = nil
        layer.strokeColor = color.cgColor
        layer.lineWidth = width
        return layer
    }

    override func draw(_ dirtyRect: NSRect) {
        drawWash()
        // The mark itself is a layer, not a drawing: it beats, and a beat drawn
        // by hand would repaint the whole wash and its lattice thirty times a
        // second to move one ring.
        if let stroke, stroke.count > 1 { draw(stroke: stroke) }
    }

    /// The line as drawn, left open.
    ///
    /// Closing it on screen would show the user a shape they did not draw. The
    /// burn closes it for the model, which needs to read an enclosure rather
    /// than follow a hand — same split the web client makes.
    private func draw(stroke points: [CGPoint]) {
        for (color, width) in [
            (NSColor.black.withAlphaComponent(0.45), CGFloat(6)),
            (Self.iris, CGFloat(3)),
        ] {
            color.setStroke()
            let path = NSBezierPath()
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.lineWidth = width
            path.stroke()
        }
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
        Self.tint.setFill()
        bounds.fill()
        Self.lattice.setFill()
        bounds.fill()

        guard let cursor else { return }
        context.saveGState()
        // Erase rather than paint: `destinationOut` takes the gradient's alpha
        // out of what is already there — tint and lattice together — which is
        // what makes the edge of the light as soft as the gradient itself.
        context.setBlendMode(.destinationOut)
        // The web client's stops, inverted: theirs is a mask where opaque means
        // "keep the wash", so the amount erased here is one minus that. Enough
        // of them that a soft edge this large does not band.
        let stops: [(CGFloat, CGFloat)] = [
            (0, 1), (0.50, 1), (0.58, 0.90), (0.66, 0.70),
            (0.74, 0.45), (0.82, 0.22), (0.91, 0.07), (1, 0),
        ]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops.map { NSColor(white: 1, alpha: $0.1).cgColor } as CFArray,
            locations: stops.map(\.0)
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: cursor,
                startRadius: 0,
                endCenter: cursor,
                endRadius: Self.spotlightReach,
                options: []
            )
        }
        context.restoreGState()
    }

    /// A ring with a crosshair, never a filled dot: what was pointed at has to
    /// stay visible, or the mark hides the answer's subject.
}
