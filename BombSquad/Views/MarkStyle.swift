import AppKit
import SwiftUI

/// The two shapes of "this one".
///
/// A ring at a place until the element is measured, then the element's own
/// frame. One type, so the two cannot drift apart into two features that mean
/// the same thing and do not look alike.
enum MarkShape {
    case ring(CGPoint)
    case frame(CGRect)

    /// The stroked outline, and — as `spread` grows — what a beat radiates out
    /// to. Radiating a fixed distance rather than scaling: a frame can be a
    /// button or an 800-point toolbar, and doubling the second one throws a ring
    /// across half the screen.
    func path(spread: CGFloat) -> NSBezierPath {
        switch self {
        case .ring(let centre):
            let radius = MarkStyle.ringRadius + spread
            return NSBezierPath(ovalIn: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2
            ))
        case .frame(let rect):
            let outset = MarkStyle.frameOutset + spread
            return NSBezierPath(
                roundedRect: rect.insetBy(dx: -outset, dy: -outset),
                xRadius: MarkStyle.frameCornerRadius + spread,
                yRadius: MarkStyle.frameCornerRadius + spread
            )
        }
    }
}

/// Every colour and number the product draws with when it points at something.
///
/// One place, because the marks are drawn by surfaces that do not otherwise
/// meet: the pointing overlay draws on a window covering the whole display, the
/// guidance highlight draws in its own click-through window over another app,
/// and the bubble is SwiftUI. Those three drifted — a 3pt line here, a 2.5pt
/// line there, a red rectangle with a 10pt corner in the third — and a user who
/// meets them in one session reads them as three different features rather than
/// one product saying the same thing three times.
enum MarkStyle {
    /// Iris. **"Here, this, the thing you touched", and the actions that lead to
    /// it.** Not state: nothing that means busy, changed or wrong may borrow it,
    /// because a colour that means two things means neither.
    static let color = NSColor(srgbRed: 74 / 255, green: 80 / 255, blue: 1, alpha: 1)
    static var swiftUIColor: Color { Color(nsColor: color) }

    /// Under every mark. Iris nearly vanishes on a blue app, and a second colour
    /// would promise a second meaning — so the legibility layer is neutral.
    ///
    /// Backing, not halo: the halo is the thing that beats outward, and one word
    /// for two layers is how the next edit gives them the same width.
    static let backing = NSColor.black.withAlphaComponent(0.45)

    static let lineWidth: CGFloat = 2.5
    static let backingWidth: CGFloat = 6
    /// Backing first, then the line. For surfaces that stroke a path by hand
    /// rather than putting a layer up — the trail the user draws is a shape only
    /// they know, so it cannot be a `MarkShape`, but it is the same claim and
    /// gets the same two passes.
    static var passes: [(color: NSColor, width: CGFloat)] {
        [(backing, backingWidth), (color, lineWidth)]
    }

    static let ringRadius: CGFloat = 22
    /// How far outside the measured element the frame sits. A frame drawn on the
    /// element's own edge reads as a border the element already had.
    static let frameOutset: CGFloat = 4
    static let frameCornerRadius: CGFloat = 8

    /// How far a beat travels before it is gone, and how long one takes.
    ///
    /// A rest between beats is what makes it a beat. A pulse with no gap is a
    /// waiting spinner, which would say something about processing rather than
    /// about a place.
    static let beatSpread: CGFloat = 14
    static let beatDuration: CFTimeInterval = 1.8

    /// The room a mark needs around whatever it marks. A window sized to the
    /// element clips the beat, which is the part that carries across a screen.
    static let outerReach: CGFloat = frameOutset + beatSpread + backingWidth

    /// The whole mark as one layer: backing, line, and a beat radiating out of
    /// it. Held still under Reduce Motion.
    ///
    /// One container so a new mark replaces the old one whole; loose sublayers
    /// are how a stale ring outlives the gesture it belonged to.
    static func layer(for shape: MarkShape) -> CALayer {
        let container = CALayer()
        let outline = shape.path(spread: 0)
        container.addSublayer(stroked(outline, backing, backingWidth))
        container.addSublayer(stroked(outline, color, lineWidth))

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return container
        }

        let spread = shape.path(spread: beatSpread)
        let grow = CAKeyframeAnimation(keyPath: "path")
        grow.values = [outline.cgPath, spread.cgPath, spread.cgPath]
        grow.keyTimes = [0, 0.58, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.61, 0, 0]
        fade.keyTimes = [0, 0.58, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = beatDuration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let beat = stroked(outline, color, lineWidth)
        beat.add(group, forKey: "beat")
        container.addSublayer(beat)
        return container
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
}

/// The wash's own colour, kept apart from the mark's on purpose.
///
/// **Do not derive one from the other.** The wash is laid over the whole screen
/// at low alpha and its value was chosen for how it comes out after that; the
/// mark is drawn opaque on top of it and its value was chosen for how it reads
/// against an interface. They currently share an RGB and differ only in alpha,
/// which is exactly the coincidence that would make a future edit collapse them
/// into one constant — and then tuning the wash would move every mark in the
/// product.
enum WashStyle {
    /// Colour only — nothing here filters brightness, so the screen underneath
    /// keeps its own light and shade exactly. Raising the alpha to make it "more
    /// purple" is the trap: a flat colour drags dark screens and light screens
    /// alike toward its own lightness, and the web client measured the
    /// difference between them shrinking by a third when that was tried. Same
    /// value as the web client's wash (`app/wash.ts`).
    static let tint = NSColor(srgbRed: 74 / 255, green: 80 / 255, blue: 1, alpha: 0.40)
}
