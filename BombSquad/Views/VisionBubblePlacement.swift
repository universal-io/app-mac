import CoreGraphics

/// Everything that decides where the bubble goes.
///
/// One value rather than three loose fields, because the fault it guards
/// against is not a wrong position but a **second** one. The overlay re-places
/// the bubble whenever its height changes — an answer arriving grows it a line
/// at a time — so any code that writes here has decided the card may move, and
/// a reflow a tenth of a second later will carry that out whether or not the
/// writer meant it to. Writing "the ring must not move the bubble" in a comment
/// above `showRing` was not enough: the call to place it was taken out and the
/// assignment to the anchor left in, and the bubble went on jumping to the ring
/// on the next reflow (2026-08-25, again on 2026-08-26).
///
/// So: the only things entitled to change this are a new subject (a
/// measurement, an enclosure), the answer pointing somewhere, and the user
/// dragging the card. Showing a mark is not one of them.
struct BubbleAnchor: Equatable {
    /// The place the answer is about, when nothing was measured there.
    var point: CGPoint?
    /// The element or the enclosure the answer is about. Beats `point`: it says
    /// where the subject *is* rather than where the hand landed.
    var frame: CGRect?
    /// Where the user dragged the card. Beats both, until they point anew.
    var userTopLeft: CGPoint?
}

/// Where the answer sits relative to the place the user pointed at.
///
/// The whole point of R14 is that the answer appears beside the thing it is
/// about; a panel in the corner makes the eye travel, which is what the web
/// client measured and then abandoned. So this is the rule the web client's
/// `placeBeside` settled on, ported: beside, never on top, never off screen,
/// and never covering the frame the answer itself points at.
///
/// Pure and screen-local (Cocoa, bottom-left origin), so it can be tested
/// without a window and cannot drift from whatever the overlay happens to be
/// doing that day.
enum VisionBubblePlacement {
    /// The gap between the pointed-at spot and the bubble, and the smallest
    /// margin the bubble keeps from the edge of the screen.
    static let gap: CGFloat = 20
    static let margin: CGFloat = 12
    /// Where the bubble waits when nothing has been pointed at yet.
    static let idleMargin: CGFloat = 24

    /// The frame a card keeps when only its height changed.
    ///
    /// **Growing is not moving, so growing does not re-solve the placement.**
    /// This is the rule that kept coming undone. Where the card sits is decided
    /// by three things — the anchor, the card's size, and the rectangles it must
    /// not cover — and the invariant has only ever been written about the first
    /// of them. But a click changes the other two on its own: the answer is
    /// swapped for "ここを読んでいます…" so the height changes, and the measured
    /// frame is cleared out of `avoid`. Re-solving then lands the card somewhere
    /// else with nobody having touched the anchor, and a reflow timer re-solves
    /// every tenth of a second. Guarding the anchor could never hold this shut;
    /// only not re-solving can.
    ///
    /// So a reflow keeps the top-left and lets the card grow downward, the way a
    /// paragraph arrives. The only movement left is the clamp that keeps it on
    /// screen. The current frame is read from the window rather than stored,
    /// which is also what makes a position the user dragged the card to survive
    /// every resize after it.
    static func resized(_ frame: CGRect, to size: CGSize, in bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: frame.minX, y: frame.maxY - size.height)
        let lowest = bounds.minY + margin
        let highest = max(lowest, bounds.maxY - margin - size.height)
        origin.y = min(max(origin.y, lowest), highest)
        let leftmost = bounds.minX + margin
        let rightmost = max(leftmost, bounds.maxX - margin - size.width)
        origin.x = min(max(origin.x, leftmost), rightmost)
        return CGRect(origin: origin, size: size)
    }

    /// - Parameters:
    ///   - point: the pointed-at spot, or nil when nothing has been pointed at.
    ///   - size: the bubble's measured size.
    ///   - bounds: the area the bubble may occupy (screen-local; pass the
    ///     visible frame so the Dock and the menu bar are already excluded).
    ///   - avoid: rectangles the bubble must not cover — the frame drawn around
    ///     what the user pointed at, and any frame the answer points at. Those
    ///     are the two things a bubble sitting on top of them would hide.
    static func origin(
        for point: CGPoint?,
        size: CGSize,
        in bounds: CGRect,
        avoid: [CGRect] = []
    ) -> CGPoint {
        guard let point else {
            // Bottom-right, where a notice with no place on the picture
            // belongs. On macOS this is inside the visible frame, so it clears
            // the Dock without knowing anything about it.
            return CGPoint(
                x: bounds.maxX - size.width - idleMargin,
                y: bounds.minY + idleMargin
            )
        }

        // Right-below first, then the three mirrors. The order matters: reading
        // order puts the answer where the eye already travels after clicking.
        let candidates = [
            CGPoint(x: point.x + gap, y: point.y - gap - size.height),
            CGPoint(x: point.x - gap - size.width, y: point.y - gap - size.height),
            CGPoint(x: point.x + gap, y: point.y + gap),
            CGPoint(x: point.x - gap - size.width, y: point.y + gap),
        ]

        for origin in candidates {
            let rect = CGRect(origin: origin, size: size)
            guard fits(rect, in: bounds) else { continue }
            guard !avoid.contains(where: { $0.intersects(rect) }) else { continue }
            return origin
        }
        // Nothing was clean: keep the preferred side and push it on screen.
        // A bubble half off the display is worse than one that overlaps a
        // frame, because the text stops being readable at all.
        return clamp(CGRect(origin: candidates[0], size: size), into: bounds).origin
    }

    /// Where the answer sits when the answer itself has pointed at a frame.
    ///
    /// The frame is the thing being explained, so the bubble keeps to its side.
    /// The click and the frame are not always the same place — the model
    /// reaches for what it believes the subject is — and words anchored to the
    /// click while the frame sits on another element read as two unrelated
    /// claims about the screen (2026-08-24: GitLab has two "+" buttons; the
    /// frame landed on one while the bubble stayed beside the other, and the
    /// pair looked broken rather than merely mistaken).
    ///
    /// Right of the frame first, top edges aligned — after looking at the
    /// frame the eye continues in reading order — then its three mirrors.
    static func origin(
        besideFrame frame: CGRect,
        size: CGSize,
        in bounds: CGRect
    ) -> CGPoint {
        let candidates = [
            CGPoint(x: frame.maxX + gap, y: frame.maxY - size.height),
            CGPoint(x: frame.minX - gap - size.width, y: frame.maxY - size.height),
            CGPoint(x: frame.minX, y: frame.minY - gap - size.height),
            CGPoint(x: frame.minX, y: frame.maxY + gap),
        ]
        for origin in candidates {
            let rect = CGRect(origin: origin, size: size)
            guard fits(rect, in: bounds) else { continue }
            guard !rect.intersects(frame) else { continue }
            return origin
        }
        // Same trade as the point placement: a bubble overlapping the frame is
        // still readable, one pushed off the display is not.
        return clamp(CGRect(origin: candidates[0], size: size), into: bounds).origin
    }

    /// The one place the three rules below are chosen between.
    ///
    /// Here rather than in the overlay so that "where would the bubble go" can
    /// be asked of a `BubbleAnchor` without a window — which is what lets a test
    /// state the rule that matters: showing the ring must not change the
    /// answer this returns.
    static func origin(
        for anchor: BubbleAnchor,
        size: CGSize,
        in bounds: CGRect,
        avoid: [CGRect] = []
    ) -> CGPoint {
        if let userTopLeft = anchor.userTopLeft {
            return origin(movedTo: userTopLeft, size: size, in: bounds)
        }
        if let frame = anchor.frame {
            return origin(besideFrame: frame, size: size, in: bounds)
        }
        return origin(for: anchor.point, size: size, in: bounds, avoid: avoid)
    }

    /// Where a bubble the user dragged goes.
    ///
    /// Their position wins over both rules above until they point somewhere new
    /// — the default is beside the mark, not a place the bubble has to be — so
    /// all this does is keep it reachable. Anchored by its **top-left**: the
    /// card grows downward as an answer arrives, and holding the origin instead
    /// would slide the whole thing up out from under the pointer while somebody
    /// is reading it.
    static func origin(movedTo topLeft: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        clamp(
            CGRect(
                origin: CGPoint(x: topLeft.x, y: topLeft.y - size.height),
                size: size
            ),
            into: bounds
        ).origin
    }

    private static func fits(_ rect: CGRect, in bounds: CGRect) -> Bool {
        rect.minX >= bounds.minX + margin
            && rect.maxX <= bounds.maxX - margin
            && rect.minY >= bounds.minY + margin
            && rect.maxY <= bounds.maxY - margin
    }

    private static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var result = rect
        result.origin.x = min(
            max(rect.minX, bounds.minX + margin),
            max(bounds.maxX - rect.width - margin, bounds.minX + margin)
        )
        result.origin.y = min(
            max(rect.minY, bounds.minY + margin),
            max(bounds.maxY - rect.height - margin, bounds.minY + margin)
        )
        return result
    }
}
