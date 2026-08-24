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
    /// This is exactly the inverse of the flip `HighlightOverlayPresenter`
    /// performs to place its ring, and deliberately written as its mirror
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
}
