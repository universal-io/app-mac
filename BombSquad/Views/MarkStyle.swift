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

    // MARK: Lattice

    /// The lattice: white dots on a grid over the tint.
    ///
    /// This is the layer that says the screen is being read rather than used.
    /// The wash alone changes the colour; the dots give it a reason — a sensor
    /// looking at a surface. The gap between "I am operating this screen" and "I
    /// am pointing at it" has to be large, because a user who thinks they are
    /// operating it will click a button and get an explanation instead.
    ///
    /// Kept just above the threshold of notice: it should be found, not seen.
    /// It was 2pt dots on a 22pt grid — 0.65% of the surface — and at that size
    /// they were below being found rather than just below being noticed. Bigger
    /// and further apart is the trade that keeps it a lattice: 4pt on 25pt is
    /// three times the ink with a fifth fewer dots, so the pattern reads as a
    /// grid of points rather than as grain.
    ///
    /// **The alpha is nowhere near its ceiling** (0.16 of 1). If this still
    /// reads faint on a real screen, that is the number to turn, and it can go
    /// a long way before it runs out.
    ///
    /// 25pt read as too many dots on a real screen (2026-08-26), and so did
    /// 30pt; each step to the next is about seven tenths as many dots, same
    /// dot, same white.
    static let latticeSpacing: CGFloat = 36
    static let latticeDotWidth: CGFloat = 4
    static let latticeAlpha: CGFloat = 0.16

    // MARK: Gravity

    /// How far the cursor's pull on the lattice reaches, and how hard it pulls
    /// at the centre.
    ///
    /// The dots gather toward the pointer the way a field bends toward a mass:
    /// strongest close in, easing off smoothly to nothing at `gravityReach`.
    /// The spotlight erases the lattice nearest the cursor (clear to 336pt,
    /// faded out by 672pt), so the well itself is never seen — what shows is
    /// the surrounding field leaning in. The reach is set so that field has an
    /// outside: dots past it stand still, and the eye can see where the pull
    /// ends. A reach wide enough to move every dot on the display was tried
    /// first (1400pt) and read as nothing in particular, because there was
    /// nothing unmoved to compare against.
    ///
    /// `gravityPull` is the fraction of its distance a dot at the centre moves
    /// inward; 0.35 makes the grid there about 2.4× as dense.
    static let gravityReach: CGFloat = 900
    static let gravityPull: CGFloat = 0.35

    /// Where a lattice point ends up under the pull of `centre`.
    ///
    /// Pure geometry so it can be tested: the pull is always toward the centre,
    /// falls off as the square of the remaining distance, is zero at and beyond
    /// the reach, and never carries a point past the centre.
    static func gravity(displacing point: CGPoint, toward centre: CGPoint) -> CGPoint {
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0, distance < gravityReach else { return point }
        let remaining = 1 - distance / gravityReach
        let pull = gravityPull * remaining * remaining
        return CGPoint(x: centre.x + dx * (1 - pull), y: centre.y + dy * (1 - pull))
    }

    /// The sheet: tint, then the lattice, optionally bent toward `gravity`.
    ///
    /// Drawn dot by dot rather than as a pattern tile, because a bent grid is not
    /// a repeating tile. Each dot is its own `fillEllipse` on purpose: measured
    /// on a 1728×1117 sheet (4,134 dots), one path holding every ellipse took
    /// 14 ms to fill and one fill per dot took 5 ms — a single huge path pays
    /// for a scanline pass over the whole sheet. The grid extends past the
    /// bounds by the furthest any dot can travel, so dots pulled in from just
    /// outside arrive instead of leaving a bare edge.
    static func drawSheet(in bounds: CGRect, gravity centre: CGPoint?, context: CGContext) {
        context.setFillColor(tint.cgColor)
        context.fill(bounds)

        let spacing = latticeSpacing
        let dot = latticeDotWidth
        // The furthest a dot moves is at a third of the reach: r·pull·(2/3)².
        let margin = spacing * ceil(gravityReach / 3 * gravityPull * 4 / 9 / spacing)
        let columns = Int(ceil((bounds.width + margin * 2) / spacing))
        let rows = Int(ceil((bounds.height + margin * 2) / spacing))
        let originX = bounds.minX - margin + spacing / 2
        let originY = bounds.minY - margin + spacing / 2

        context.setFillColor(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: latticeAlpha).cgColor)
        for row in 0..<rows {
            for column in 0..<columns {
                var point = CGPoint(
                    x: originX + CGFloat(column) * spacing,
                    y: originY + CGFloat(row) * spacing
                )
                if let centre { point = gravity(displacing: point, toward: centre) }
                guard bounds.insetBy(dx: -dot, dy: -dot).contains(point) else { continue }
                context.fillEllipse(in: CGRect(
                    x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot
                ))
            }
        }
    }

    // MARK: Sweep

    /// The sheet arrives behind a line of light: how the wash says "reading".
    ///
    /// The same entrance on the way in (right Shift twice) and every time
    /// guidance takes the screen again, so the two are recognisably one act.
    /// Bottom to top, once, accelerating — the light is not a thing passing
    /// over a sheet that is already there; it is the front edge of the sheet
    /// itself, and everything below it is what has been read. A band passing
    /// over a wash that had already appeared was tried and read as an
    /// unrelated effect (2026-08-26).
    static let sweepDuration: CFTimeInterval = 0.42
    /// The light at the front edge, and how far the edge is feathered.
    static let sweepBandHeight: CGFloat = 120
    static let sweepPeakAlpha: CGFloat = 0.22
    static let sweepEdgeSoftness: CGFloat = 80

    /// Reveals `host` from the bottom up behind a line of light, then leaves
    /// it fully shown. Nothing is added under Reduce Motion — the sheet
    /// appearing is the whole cue there.
    ///
    /// Works by masking the host: the mask is opaque below the front edge and
    /// clear above it, twice the height of the sheet so that at rest it covers
    /// everything. The mask comes off at the end so nothing is left in the
    /// layer tree that a later mark could be clipped by.
    static func sweep(over host: CALayer, in bounds: CGRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let height = bounds.height
        let soft = sweepEdgeSoftness

        // Layer space is not flipped: the bottom of the sheet is the smaller y,
        // and the front edge is the middle of the mask.
        let mask = CAGradientLayer()
        mask.colors = [
            NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor,
        ]
        mask.locations = [0, 0.5, NSNumber(value: 0.5 + Double(soft / (height * 2)))]
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: height * 2)
        let edgeStart = bounds.minY - soft
        let edgeEnd = bounds.maxY + soft
        mask.position = CGPoint(x: bounds.midX, y: edgeEnd)

        let band = CAGradientLayer()
        band.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(sweepPeakAlpha).cgColor,
        ]
        band.startPoint = CGPoint(x: 0.5, y: 0)
        band.endPoint = CGPoint(x: 0.5, y: 1)
        band.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: sweepBandHeight)
        // The band sits just inside the revealed part, brightest at the edge.
        let bandOffset = -sweepBandHeight / 2
        band.position = CGPoint(x: bounds.midX, y: edgeEnd + bandOffset)

        // Accelerating hard: the read starts deliberately and finishes in a
        // rush. The system easeIn (0.42, 0, 1, 1) was too gentle a curve on a
        // real screen; this one holds back longer and then goes.
        let timing = CAMediaTimingFunction(controlPoints: 0.7, 0, 0.84, 0)
        func travel(from: CGFloat, to: CGFloat) -> CABasicAnimation {
            let move = CABasicAnimation(keyPath: "position.y")
            move.fromValue = from
            move.toValue = to
            move.duration = sweepDuration
            move.timingFunction = timing
            return move
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            if host.mask === mask { host.mask = nil }
            band.removeFromSuperlayer()
        }
        host.mask = mask
        host.addSublayer(band)
        mask.add(travel(from: edgeStart, to: edgeEnd), forKey: "sweep")
        band.add(travel(from: edgeStart + bandOffset, to: edgeEnd + bandOffset), forKey: "sweep")
        CATransaction.commit()
    }
}
