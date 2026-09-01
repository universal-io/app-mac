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
/// It has two states, and the wash is the difference between them (R15).
/// **Pointing**: the wash is up, a click is a question. **Guiding**: the wash is
/// gone, a click is an action on the app underneath, and the only thing this
/// overlay still draws is the frame around the control the guidance named. The
/// user in the first field test read the instruction and clicked the named
/// control, and the wash swallowed it as a question — so the two cannot share a
/// screen, and which one is up is what tells the user what a click will do.
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
    /// The bubble's own window, a child of the cover.
    ///
    /// It used to be a subview of the canvas, which was the simplest thing that
    /// worked while the cover always took clicks. Guiding needs the cover to
    /// stop taking them (`ignoresMouseEvents`), and that is a property of a
    /// whole window — a bubble inside it would go click-through too. A child
    /// window keeps its own answer to that question, moves with its parent, and
    /// was measured (R15 G1) to take clicks, commit Japanese IME text and hold
    /// key while another application stays frontmost.
    private var bubblePanel: NonactivatingOverlayPanel?
    private var bubble: NSHostingView<AnyView>?
    private var screenFrame: CGRect = .zero
    /// Where the bubble is anchored, which outlives the drawn mark: once the
    /// answer's own frame is up the mark retracts, but the bubble keeps a place
    /// on the picture rather than retreating to the corner.
    ///
    /// Read by the reflow as well as by the gestures, so **who is allowed to
    /// write it is the whole of the rule** — see `BubbleAnchor`. Internal so a
    /// test can hold the ring to it.
    private(set) var bubbleAnchor = BubbleAnchor()
    /// Kept so the bubble can be re-placed when its own size changes.
    private var placedSize: CGSize = .zero
    private var reflow: Timer?
    /// Follows the pointer for the spotlight. A monitor rather than the canvas's
    /// own `mouseMoved`, because the bubble is now a second window: moved events
    /// over it never reach the canvas, and the light would stop at the bubble's
    /// edge and stay there — a light that lies about where the pointer is reads
    /// worse than no light (`app-web/docs/solo-mode.md` §1).
    private var cursorMonitor: Any?
    private var washFade: Timer?
    private var bubbleMoveObserver: Any?
    /// Whether the frame currently drawn is the answer's rather than the
    /// user's own gesture. `clearAnswerFrame` is only entitled to take down the
    /// first kind: guidance takes its frame off the moment the user clicks, and
    /// the same call reaches here at the start of every pointing turn, where it
    /// would wipe the ring drawn a moment earlier.
    private var showsAnswerFrame = false
    /// True while `placeBubble` is setting the frame, so the move it causes is
    /// not mistaken for the user dragging the bubble there — that would pin it
    /// to wherever it was first placed and nothing would ever move it again.
    private var isPlacingBubble = false

    /// Whether clicks currently belong to the app underneath.
    private(set) var isGuiding = false

    var isVisible: Bool { panel?.isVisible == true }

    /// The bubble's rectangle, in global Cocoa coordinates.
    ///
    /// Guidance needs it to tell a click on the bubble from a click on the app
    /// it is guiding: the first is somebody moving the answer out of the way or
    /// pressing 再確認, and counting it as progress spends a capture and a
    /// request on nothing.
    var bubbleCardFrame: CGRect? { bubblePanel?.frame }
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
            // The click made the cover key. Typing right after pointing is the
            // ordinary next move, so key goes back to the window with the field.
            self.bubblePanel?.makeKey()
        }
        // Drawn while the hand is still moving, so the line appears under the
        // cursor rather than after the gesture ends.
        canvas.onPathChanged = { [weak self] path in self?.showStroke(path) }
        canvas.onClose = { [weak self] in self?.onClose?() }

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

        let bubblePanel = NonactivatingOverlayPanel()
        // AppKit's shadow, not SwiftUI's. A shadow drawn inside the view needs
        // the window to be bigger than the card to hold it, and every point of
        // that margin is a point where a click lands on us instead of on the
        // app being guided — an inch-wide ring around the bubble where pressing
        // a button does nothing. A window shadow falls outside the frame and is
        // click-through, so the window can be exactly the card.
        bubblePanel.hasShadow = true
        let bubbleHost = BubbleHostView(frame: .zero)
        bubbleHost.onClose = { [weak self] in self?.onClose?() }
        bubbleHost.addSubview(host)
        bubblePanel.contentView = bubbleHost

        panel.contentView = canvas
        panel.orderFrontRegardless()
        // The wash arrives with the same pass of light guidance uses when it
        // takes the screen again, so entering and re-reading read as one act.
        wash.sweep()
        // A child, so it is ordered with the cover and never slips behind it.
        panel.addChildWindow(bubblePanel, ordered: .above)

        self.panel = panel
        self.canvas = canvas
        self.bubble = host
        self.bubblePanel = bubblePanel
        isGuiding = false
        placeBubble()
        // Key without activating: see NonactivatingOverlayPanel. The window with
        // the field takes it, so the first keystroke lands in the question.
        bubblePanel.makeKey()

        cursorMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.trackCursor() }
            return event
        }
        // Any movement of the bubble's own window that this class did not
        // perform is the user dragging it. Watching the window rather than the
        // handle keeps the two sides independent: the bubble asks AppKit to
        // drag its window, and the placement finds out from AppKit.
        bubbleMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: bubblePanel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteBubbleMoved() }
        }

        // The bubble grows while an answer streams in, and AppKit does not tell
        // a superview that a hosting view's content got taller. Ten times a
        // second is below noticing, costs a size comparison, and keeps the
        // bubble beside the mark through the whole of an answer arriving.
        reflow = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeBubbleIfResized() }
        }
    }

    // MARK: - The two states

    /// Hands the screen back. The wash fades, clicks go to the app underneath,
    /// and the frame around the named control stays.
    ///
    /// `ignoresMouseEvents` flips first, not after the fade: the instruction is
    /// already on screen and the user is already reaching for the control. The
    /// redraw is deliberate as well — the window server was measured to apply
    /// the flag lazily, and a flush is the one thing known to accompany it
    /// taking effect (R15 G1).
    func enterGuiding() {
        guard let panel, !isGuiding else { return }
        isGuiding = true
        canvas?.wash?.stroke = nil
        panel.ignoresMouseEvents = true
        fadeWash(to: 0)
        panel.displayIfNeeded()
    }

    /// Takes the screen again: clicks are questions, the wash says so, and the
    /// field is ready for the next one.
    func enterPointing() {
        guard let panel, isGuiding else { return }
        isGuiding = false
        panel.ignoresMouseEvents = false
        fadeWash(to: 1)
        panel.displayIfNeeded()
        bubblePanel?.makeKey()
    }

    // MARK: - Marks

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
    /// The click, answered on the spot.
    ///
    /// **The bubble does not move for this, and this does not touch the
    /// anchor.** A ring and the frame around the element under it are rarely in
    /// the same place, so placing the bubble twice — once beside the pixel,
    /// then again beside the element about half a second later — reads as the
    /// card being shoved around rather than arriving. The ring's job is to say
    /// the click was heard, which it does where the hand already is; where the
    /// answer goes is settled once the screen has been measured.
    ///
    /// Not calling `placeBubble` is not enough on its own, which is how this
    /// came back: `beginPointing` follows immediately and swaps the previous
    /// answer for "ここを読んでいます…", the bubble's height changes, and the
    /// reflow places it against whatever the anchor says a tenth of a second
    /// later. Leaving the anchor alone is what holds the card still — it keeps
    /// pointing at the subject of the turn that is ending until the next one
    /// has been measured.
    func showRing(at point: CGPoint) {
        showsAnswerFrame = false
        canvas?.wash?.stroke = nil
        canvas?.wash?.markShape = .ring(point)
        canvas?.wash?.hitFrame = nil
    }

    /// What the screen turned out to hold there.
    ///
    /// Called once per gesture, after the accessibility walk. **The card moves
    /// only if something was measured.** A ring says a click was heard; it does
    /// not say where the subject is, and the element under it is somewhere else
    /// — so going to the ring first and to the element a moment later is two
    /// moves for one gesture, in the order that looks worst: the card runs to
    /// the finger, starts explaining there, and then leaves. With nothing
    /// measured there is no place to go, so the card stays where it is and the
    /// answer's own frame moves it later if one arrives.
    func setMark(point: CGPoint?, frame: CGRect?) {
        // The whole anchor at once: a new subject spends the position the user
        // chose for the last one (pointing somewhere else is the gesture that
        // says "put it where it belongs again"), and whatever the previous
        // answer pointed at no longer decides where this one appears.
        bubbleAnchor = BubbleAnchor(frame: frame)
        showsAnswerFrame = false
        canvas?.wash?.stroke = nil
        canvas?.wash?.markShape = frame.map(MarkShape.frame)
            ?? Self.drawnMark(point: point, frame: frame).map(MarkShape.ring)
        canvas?.wash?.hitFrame = frame
        // Nothing measured, nothing to move to. Placing here would put the card
        // in the corner it waits in, which is a move away from the subject
        // rather than towards one.
        guard frame != nil else { return }
        placeBubble()
    }

    /// Same element, measured twice by two different paths.
    ///
    /// The rect the accessibility walk returns and the one the answer points at
    /// travel through separate conversions, so the same control can arrive a
    /// fraction of a point apart. That is not a new subject and must not move
    /// the card; a point is far below what anybody can see and far above the
    /// rounding involved.
    nonisolated static func isEssentiallyTheSame(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else { return false }
        let tolerance: CGFloat = 1
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
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
        bubbleAnchor = BubbleAnchor(frame: VisionPointerResolver.bounds(of: path))
        showsAnswerFrame = false
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
    ///
    /// In guiding this is the whole display: the frame around the control to
    /// press, beating, until the press.
    /// - Parameter movesBubble: false once the user has started reading. The
    ///   answer's target is only known from the final validated object, so on a
    ///   turn that streamed its text this arrives seconds after the first line —
    ///   and moving the card out from under somebody mid-sentence is worse than
    ///   the card being a little away from the frame. The mark still goes to the
    ///   right place; only the card stays put.
    func showAnswerFrame(_ frame: CGRect, movesBubble: Bool = true) {
        showsAnswerFrame = true
        canvas?.wash?.markShape = .frame(frame)
        canvas?.wash?.stroke = nil
        canvas?.wash?.hitFrame = frame
        guard movesBubble else { return }
        // The bubble follows the frame: from here on the words sit beside the
        // element they are about, which is not always the one that was measured
        // under the click. When it is the same one, nothing moves — the card is
        // already beside it, and a move to where it already is would only be
        // visible as a twitch. A position the user chose is left standing: they
        // moved the card during this same turn, about this same subject.
        guard !Self.isEssentiallyTheSame(bubbleAnchor.frame, frame) else {
            return
        }
        bubbleAnchor.frame = frame
        placeBubble()
    }

    /// The frame comes down without the bubble moving.
    ///
    /// Guidance takes the frame off the moment the user clicks — the screen is
    /// about to change and a frame on the old control would be a claim about a
    /// screen that no longer exists — and puts a new one up when the next
    /// instruction arrives. The bubble keeps its place through that wait: one
    /// that jumps to the corner every time the user acts reads as the product
    /// resetting.
    func clearAnswerFrame() {
        // Only the answer's own frame. Anything else on screen was put there by
        // the user's last gesture and is not this call's to remove.
        guard showsAnswerFrame else { return }
        showsAnswerFrame = false
        canvas?.wash?.markShape = nil
        canvas?.wash?.hitFrame = nil
    }

    func close() {
        bubbleAnchor = BubbleAnchor()
        reflow?.invalidate()
        reflow = nil
        washFade?.invalidate()
        washFade = nil
        if let cursorMonitor { NSEvent.removeMonitor(cursorMonitor) }
        cursorMonitor = nil
        if let bubbleMoveObserver { NotificationCenter.default.removeObserver(bubbleMoveObserver) }
        bubbleMoveObserver = nil
        if let bubblePanel {
            panel?.removeChildWindow(bubblePanel)
            bubblePanel.orderOut(nil)
        }
        panel?.orderOut(nil)
        panel = nil
        canvas = nil
        bubble = nil
        bubblePanel = nil
        placedSize = .zero
        isGuiding = false
    }

    // MARK: - Wash

    /// 0.2 seconds, the length of the wash coming or going. Long enough to read
    /// as the screen being handed over rather than as a flicker, short enough
    /// that the control is reachable before the hand gets there.
    private static let washFadeDuration: TimeInterval = 0.2

    private func fadeWash(to opacity: CGFloat) {
        washFade?.invalidate()
        washFade = nil
        guard let wash = canvas?.wash else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            wash.washOpacity = opacity
            return
        }
        let start = wash.washOpacity
        let began = Date()
        washFade = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let progress = min(1, Date().timeIntervalSince(began) / Self.washFadeDuration)
                wash.washOpacity = start + (opacity - start) * CGFloat(progress)
                if progress >= 1 {
                    timer.invalidate()
                    self?.washFade = nil
                }
            }
        }
    }

    private func trackCursor() {
        guard !isGuiding, let wash = canvas?.wash else { return }
        let global = NSEvent.mouseLocation
        wash.cursor = CGPoint(x: global.x - screenFrame.minX, y: global.y - screenFrame.minY)
    }

    // MARK: - Bubble placement

    /// Fixed width, variable height: a bubble that also changes width while a
    /// sentence arrives reads as the layout thrashing rather than as somebody
    /// speaking. The view inside uses the same constant, so there is one width.
    static let bubbleWidth: CGFloat = 380

    /// The card got taller or shorter. That is not a new subject, so the
    /// placement is not solved again — see `VisionBubblePlacement.resized`.
    private func placeBubbleIfResized() {
        guard let bubble, let bubblePanel else { return }
        let height = Self.height(of: bubble)
        guard abs(height - placedSize.height) > 0.5 else { return }
        let size = CGSize(width: Self.bubbleWidth, height: max(1, height))
        let bounds = NSScreen.screens
            .first { $0.frame == screenFrame }?
            .visibleFrame ?? screenFrame
        isPlacingBubble = true
        defer { isPlacingBubble = false }
        bubblePanel.setFrame(
            VisionBubblePlacement.resized(bubblePanel.frame, to: size, in: bounds),
            display: true
        )
        bubblePanel.invalidateShadow()
        bubble.frame = CGRect(origin: .zero, size: size)
        placedSize = size
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
        guard let bubble, let bubblePanel else { return }
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
        let origin = VisionBubblePlacement.origin(
            for: bubbleAnchor,
            size: size,
            in: bounds
        )
        // The placement is screen-local and the window is global.
        isPlacingBubble = true
        defer { isPlacingBubble = false }
        bubblePanel.setFrame(
            CGRect(
                origin: CGPoint(
                    x: origin.x + screenFrame.minX,
                    y: origin.y + screenFrame.minY
                ),
                size: size
            ),
            display: true
        )
        // The shadow is cast from the window's own alpha, and a borderless
        // window keeps the shape it had before the resize until told.
        bubblePanel.invalidateShadow()
        bubble.frame = CGRect(origin: .zero, size: size)
        placedSize = size
    }

    private func noteBubbleMoved() {
        guard !isPlacingBubble, let bubblePanel else { return }
        bubbleAnchor.userTopLeft = CGPoint(
            x: bubblePanel.frame.minX - screenFrame.minX,
            y: bubblePanel.frame.maxY - screenFrame.minY
        )
    }
}

/// The bubble window's content: the hosting view with the shadow's room around
/// it, and Esc when nothing inside is typing. The field handles its own Esc
/// (`SendableTextEditor.onEscape`); this is for the moment after a button in
/// the bubble was pressed, when key is here and no text view has it.
private final class BubbleHostView: NSView {
    var onClose: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onClose?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Routes the gesture and owns nothing else. The wash draws below it, the bubble
/// above it in its own window, and everything the user reads comes from the
/// bubble — a card in the middle of the picture covers the place they are trying
/// to look at, which the web client established the hard way.
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
    /// The one thing that says "this one" — see `MarkStyle`, which owns the
    /// shape, the colours and the numbers so that every surface draws exactly
    /// the same thing.
    var markShape: MarkShape? { didSet { renderMark() } }
    /// The line the user drew, in this view's coordinates.
    var stroke: [CGPoint]? { didSet { needsDisplay = true } }
    var hitFrame: CGRect? { didSet { needsDisplay = true } }
    var cursor: CGPoint? { didSet { needsDisplay = true } }
    /// How much of the wash is there: 1 while pointing, 0 while guiding, and in
    /// between for the length of the hand-over. The marks are unaffected — they
    /// are layers, and the one thing guidance keeps on screen.
    var washOpacity: CGFloat = 1 { didSet { needsDisplay = true } }


    /// Where the spotlight's falloff ends — not where the clear part ends. The
    /// held-clear core is half of it and every stop of the ramp is a fraction of
    /// it, so this one number resizes the whole light in proportion.
    private static let spotlightReach: CGFloat = 672

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// One pass of light down the sheet — the wash saying it is reading.
    func sweep() {
        guard let host = layer else { return }
        WashStyle.sweep(over: host, in: bounds)
    }

    private var markLayer: CALayer?

    /// Puts up whichever mark is current, and takes down the one before it.
    private func renderMark() {
        markLayer?.removeFromSuperlayer()
        markLayer = nil
        guard let markShape, let host = layer else { return }
        let mark = MarkStyle.layer(for: markShape)
        host.addSublayer(mark)
        markLayer = mark
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
        // The same two passes as a mark: the trail is the same claim in a shape
        // only the user knows, so it cannot be a `MarkShape`, but there is no
        // reason for it to be a different weight or a different purple.
        for (color, width) in MarkStyle.passes {
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
    /// The spotlight follows the cursor for as long as the wash is up, including
    /// after a question. It says where the pointer is on a screen this app has
    /// covered, and that stays true. While guiding there is no wash and no
    /// light: the screen is the user's again, and the light would say otherwise.
    private func drawWash() {
        guard washOpacity > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // One alpha for the whole sheet — tint, lattice and hole together — so
        // the hand-over fades the wash as one thing rather than as layers
        // leaving at different speeds.
        context.setAlpha(washOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        // The cursor bends the lattice as well as lighting it. Not under Reduce
        // Motion: a field that follows the pointer is the same kind of motion
        // as parallax, which that setting exists to turn off.
        let gravity = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : cursor
        WashStyle.drawSheet(in: bounds, gravity: gravity, context: context)

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
}
