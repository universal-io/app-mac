import CoreGraphics
import Foundation

/// What the user indicated on the screen, in the capture's own normalized
/// space (0-1, top-left origin) — the same space `VisionObservation.Candidate`
/// rectangles already use, and the space the Gateway's `input.pointer` is
/// defined in.
///
/// A pointer is trusted intent, not an observation: the user physically
/// indicated a place, so it decides what the answer is about. That is why it
/// outranks the screen evidence in the Gateway's prompt and why nothing here
/// may quietly widen it to the whole screen.
struct VisionPointer: Equatable {
    enum Kind: Equatable {
        /// A tap. The subject is the one control or element under the point.
        case point(CGPoint)
        /// A ring drawn around several things the user has no name for. The
        /// subject is the area as a whole.
        case region(CGRect)
    }

    let kind: Kind

    /// The path the user's hand actually drew, when the gesture was a loop.
    ///
    /// Never sent: the contract carries a point or a rectangle, and nothing
    /// else. It exists so the burned mark can be the loop itself rather than
    /// the box around it — a ring around three items in a row says something a
    /// rectangle covering their whole neighbourhood does not. Coordinates are
    /// the same normalized space as `kind`.
    let stroke: [CGPoint]?

    /// The candidate accessibility measured at the pointed spot, when there
    /// was one — the smallest candidate rectangle containing the point.
    ///
    /// The mark says where the user pointed; this says what the OS found
    /// there. Without it the model matches the mark against the picture alone
    /// and can settle on a semantically similar control elsewhere: on
    /// 2026-08-24 a click on GitLab's toolbar "+" was answered with the
    /// repository "+" while the burned mark sat exactly on the clicked
    /// element. An id, not a role or label, because the candidate list already
    /// travels with every request and the Gateway joins the two.
    let hitCandidateID: String?

    init(kind: Kind, stroke: [CGPoint]? = nil, hitCandidateID: String? = nil) {
        self.kind = kind
        self.stroke = stroke
        self.hitCandidateID = hitCandidateID
    }

    var wirePayload: [String: Any] {
        var payload: [String: Any]
        switch kind {
        case .point(let point):
            payload = [
                "kind": "point",
                "point": ["x": Double(point.x), "y": Double(point.y)],
            ]
        case .region(let rect):
            payload = [
                "kind": "region",
                "region": [
                    "x": Double(rect.minX),
                    "y": Double(rect.minY),
                    "w": Double(rect.width),
                    "h": Double(rect.height),
                ],
            ]
        }
        if let hitCandidateID {
            payload["hit_candidate_id"] = hitCandidateID
        }
        return payload
    }
}

/// What one finished hand gesture meant.
///
/// A press that stayed put is a tap; one that travelled is an enclosure. The
/// two are told apart by geometry alone — never by whether the shape looks
/// deliberate. Dragging straight across a line of text is a legitimate way to
/// say "this line", so a straightness test would reject the gesture people
/// actually make (`app-web/docs/solo-mode.md` §1).
enum VisionGesture: Equatable {
    case point(CGPoint)
    /// The path as drawn, in the order it was drawn.
    case region([CGPoint])
}

/// Turns a mouse location into a pointer, and a pointer into the element it
/// landed on.
///
/// Pure by construction. Every coordinate bug this product has paid for came
/// from a second formula written somewhere else (`OverlayWindow` carries the
/// note about the same secondary-display offset appearing twice), so the
/// conversion lives here once and the overlay does no arithmetic of its own.
enum VisionPointerResolver {
    /// Cocoa global (bottom-left origin of the main display, what
    /// `NSEvent.mouseLocation` reports) → CG global (top-left origin, what
    /// `ScreenshotAttachment.captureRect` and AX frames use).
    ///
    /// This is exactly the inverse of the flip `screenLocalRect` performs to
    /// put a frame back on the screen, and deliberately written as its mirror
    /// rather than derived again. Displays left of or above the main one have
    /// negative origins in both spaces, which is why only the main display's
    /// height appears here.
    static func globalCGPoint(
        cocoaGlobal point: CGPoint,
        mainDisplayHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    /// CG global point → the capture's normalized space, or nil when the point
    /// is outside the captured area.
    ///
    /// Returning nil rather than clamping is the point: a click on a display we
    /// did not capture is not a click at the edge of the one we did, and
    /// answering about the edge would be answering about something the user
    /// never indicated.
    static func normalized(
        _ point: CGPoint,
        within captureRect: CGRect
    ) -> CGPoint? {
        guard captureRect.width > 0, captureRect.height > 0 else { return nil }
        let normalized = CGPoint(
            x: (point.x - captureRect.minX) / captureRect.width,
            y: (point.y - captureRect.minY) / captureRect.height
        )
        guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else {
            return nil
        }
        return normalized
    }

    /// The rect form of the point conversion above: a CG global rectangle as a
    /// fraction of the capture, clipped to it, or nil when none of it falls
    /// inside. Written beside the point version so both stay one arithmetic — a
    /// frame that follows its element across a scroll comes through here and
    /// nowhere else, and a projection of its result by `screenLocalRect` lands
    /// where `cocoaGlobalRect` puts the same AX frame (pinned by a test).
    static func normalized(_ rect: CGRect, within captureRect: CGRect) -> CGRect? {
        guard captureRect.width > 0, captureRect.height > 0 else { return nil }
        let visible = rect.intersection(captureRect)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return CGRect(
            x: (visible.minX - captureRect.minX) / captureRect.width,
            y: (visible.minY - captureRect.minY) / captureRect.height,
            width: visible.width / captureRect.width,
            height: visible.height / captureRect.height
        )
    }

    /// A normalized capture rectangle placed back onto the real screen, in the
    /// coordinates of a window covering `screenFrame`.
    ///
    /// The way back out. Candidate rectangles are fractions of the capture, so
    /// drawing one on the live screen means undoing the same two steps in the
    /// same order — capture space to CG global, CG global to Cocoa — and
    /// subtracting the screen the overlay covers. Written here beside the
    /// forward conversion so the pair can be read at once; a frame drawn by
    /// some other arithmetic is how a highlight ends up one row off.
    static func screenLocalRect(
        normalized rect: CGRect,
        captureRect: CGRect,
        mainDisplayHeight: CGFloat,
        screenFrame: CGRect
    ) -> CGRect {
        let global = CGRect(
            x: captureRect.minX + rect.minX * captureRect.width,
            y: captureRect.minY + rect.minY * captureRect.height,
            width: rect.width * captureRect.width,
            height: rect.height * captureRect.height
        )
        return CGRect(
            x: global.minX - screenFrame.minX,
            y: (mainDisplayHeight - global.maxY) - screenFrame.minY,
            width: global.width,
            height: global.height
        )
    }

    /// An accessibility frame placed into Cocoa global coordinates.
    ///
    /// AX reports frames top-left-origin, anchored to the display carrying the
    /// menu bar; window placement speaks bottom-left from the same anchor. This
    /// is `screenLocalRect`'s flip without the screen subtraction, and it lives
    /// here for the reason the other two do: **the main display's height enters
    /// this file and nowhere else.** A conversion written next to its caller is
    /// how the same rectangle ends up in two spaces — the flip is one line, it
    /// survives review, and the second display is where it shows.
    ///
    /// An empty frame is no anchor: a zero-sized element is a read that
    /// technically succeeded about a place that cannot be sat beside.
    static func cocoaGlobalRect(
        axFrame frame: CGRect?,
        mainDisplayHeight: CGFloat
    ) -> CGRect? {
        guard let frame, !frame.isEmpty else { return nil }
        return CGRect(
            x: frame.minX,
            y: mainDisplayHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// The height every conversion here measures against: the display carrying
    /// the menu bar, which is the origin of both spaces.
    ///
    /// One accessor rather than a literal at each call site, because the two
    /// obvious spellings — this one and `NSScreen.screens.first?.frame.maxY` —
    /// agree today and are not the same expression. Having both in the tree
    /// invites a future edit to fix one of them.
    static var mainDisplayHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    /// The one candidate the user pointed at: the smallest whose rectangle
    /// contains the point.
    ///
    /// Smallest, because containment alone is ambiguous — a button sits inside
    /// its toolbar, which sits inside its window, and all three contain the
    /// click. The innermost of those is the thing a person means when they
    /// point at it.
    ///
    /// The result is used to place the bubble beside real pixels and to draw
    /// the frame. It is never sent as the answer's justification: the Gateway
    /// strips candidate rectangles before the model sees them, so what the
    /// model has to go on is the mark burned into the image.
    static func candidate(
        at point: CGPoint,
        in candidates: [VisionObservation.Candidate]
    ) -> VisionObservation.Candidate? {
        candidates
            .filter { candidate in
                guard let rect = candidate.rect else { return false }
                return rect.contains(point)
            }
            .min { left, right in
                area(of: left) < area(of: right)
            }
    }

    private static func area(of candidate: VisionObservation.Candidate) -> CGFloat {
        guard let rect = candidate.rect else { return .greatestFiniteMagnitude }
        return rect.width * rect.height
    }

    // MARK: - Gestures

    /// How far the hand has to travel before a click becomes an enclosure.
    ///
    /// Screen points, so it means the same distance on any display. Measured
    /// across the path's own bounds rather than from where the press began: a
    /// ring comes back near its start, and asking "how far is the cursor from
    /// the start" would call a completed circle a click.
    static let enclosureThreshold: CGFloat = 8

    /// What a finished path meant. Nil for an empty path.
    static func gesture(from path: [CGPoint]) -> VisionGesture? {
        guard let first = path.first else { return nil }
        let box = bounds(of: path)
        guard max(box.width, box.height) >= enclosureThreshold else {
            return .point(first)
        }
        return .region(path)
    }

    static func bounds(of path: [CGPoint]) -> CGRect {
        guard let first = path.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in path.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The enclosed area, as the wire contract requires it: inside the unit
    /// square with both sides greater than zero.
    ///
    /// A drag straight across a line of text — the gesture that says "this
    /// line" — encloses a rectangle zero points tall, and the Gateway rejects a
    /// zero-area region as a click that dragged nowhere. That is the right rule
    /// for a stray event and the wrong answer for a deliberate stroke, so the
    /// degenerate axis is opened to a floor around its own centre instead. The
    /// burned mark is the path itself, so this rectangle only has to state
    /// which part of the picture the question is about.
    static func normalizedRegion(from path: [CGPoint]) -> CGRect? {
        guard path.count > 1 else { return nil }
        // A thousandth of the image is invisible in the mark and enough to be
        // an area rather than a line.
        let floorExtent: CGFloat = 0.004
        var rect = bounds(of: path)
        if rect.width < floorExtent {
            rect.origin.x = rect.midX - floorExtent / 2
            rect.size.width = floorExtent
        }
        if rect.height < floorExtent {
            rect.origin.y = rect.midY - floorExtent / 2
            rect.size.height = floorExtent
        }
        // Widening can push a stroke drawn at the very edge outside the image.
        rect.origin.x = min(max(rect.minX, 0), 1 - rect.width)
        rect.origin.y = min(max(rect.minY, 0), 1 - rect.height)
        guard rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= 1, rect.maxY <= 1,
              rect.width > 0, rect.height > 0
        else { return nil }
        return rect
    }
}
