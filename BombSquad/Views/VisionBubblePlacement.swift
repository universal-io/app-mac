import CoreGraphics

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
