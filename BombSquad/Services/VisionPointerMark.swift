import AppKit

/// Burns the user's gesture into the image before it is sent.
///
/// Telling a model "the user tapped at x=0.42, y=0.31" asks it to map two
/// fractions onto a picture, which is the one thing these models are reliably
/// bad at — the web client's first real run pointed at a button in the middle
/// of the screen and got back an explanation of the window's close button in
/// the corner. The same model draws accurate boxes when it chooses the target
/// itself, so reading coordinates off an image is not the problem; deriving a
/// position from arithmetic is. Drawing the mark turns that arithmetic into
/// something the model can simply see, and the Gateway's prompt tells it to
/// trust the mark over the numbers.
///
/// **This is not optional on macOS.** The capture excludes this whole
/// application, so anything drawn on the pointing overlay — the ring the user
/// sees, the frame around the element — is absent from the pixels the model
/// receives. The image bytes are the only channel that can carry "here".
///
/// Geometry is a port of the web client's `lib/marker.ts` so both products
/// present the model with the same mark; a second dialect would make their
/// answers incomparable.
enum VisionPointerMark {
    /// Magenta: effectively absent from real interface chrome, so the mark
    /// cannot be mistaken for part of the screen underneath it.
    ///
    /// **Deliberately not the colour of the mark the user sees.** That one is
    /// iris (`MarkStyle`), and the two must not be made to match: this is a
    /// signal to a model and that is a signal to a person, and a reader who saw
    /// them as the same thing would conclude the app draws on the screenshots it
    /// keeps.
    private static let markColor = NSColor(srgbRed: 1, green: 0, blue: 0.898, alpha: 1)
    private static let outerColor = NSColor.white
    private static let midColor = NSColor.black

    /// Returns a new bitmap with the gesture drawn on top, or nil when a
    /// drawing context could not be made.
    ///
    /// Drawn at the size actually being sent, after any downscale, so the line
    /// stays one thickness rather than being thinned by resampling — and so the
    /// radius means the same fraction of the picture the model sees.
    ///
    /// A hand-drawn loop is burned as the path itself rather than its bounding
    /// box: a ring around three items in a row says something a rectangle
    /// covering their whole neighbourhood does not.
    static func burn(
        _ pointer: VisionPointer,
        into bitmap: NSBitmapImageRep
    ) -> NSBitmapImageRep? {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return nil }

        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        let size = NSSize(width: width, height: height)
        target.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        bitmap.draw(in: NSRect(origin: .zero, size: size))

        // Scaled to the image rather than fixed in pixels, so the mark reads the
        // same on a 1280-wide capture and a 3400-wide one.
        let unit = CGFloat(max(width, height))
        let strokeWidth = max(2, unit * 0.004)

        switch pointer.kind {
        case .point(let point):
            let centre = pixelPoint(point, width: width, height: height)
            ring(at: centre, radius: unit * 0.022, strokeWidth: strokeWidth)
        case .region(let region):
            if let path = pointer.stroke, path.count > 1 {
                loop(path.map { pixelPoint($0, width: width, height: height) }, strokeWidth: strokeWidth)
            } else {
                rectangle(pixelRect(region, width: width, height: height), strokeWidth: strokeWidth)
            }
        }
        return target
    }

    /// Normalized (top-left origin, the space pointers and candidates live in)
    /// → the bitmap context's own space, which AppKit gives a bottom-left
    /// origin. The flip belongs here, at the boundary, rather than in the
    /// resolver whose numbers are shared with the Gateway.
    private static func pixelPoint(_ point: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(
            x: point.x * CGFloat(width),
            y: (1 - point.y) * CGFloat(height)
        )
    }

    private static func pixelRect(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width)
        let h = CGFloat(height)
        return CGRect(
            x: rect.minX * w,
            y: (1 - rect.maxY) * h,
            width: rect.width * w,
            height: rect.height * h
        )
    }

    /// A ring, never a filled dot: whatever was pointed at has to stay visible,
    /// or the mark hides the thing the answer is about. The short crosshair
    /// makes the exact spot unambiguous when the ring happens to enclose
    /// several small controls.
    private static func ring(at centre: CGPoint, radius: CGFloat, strokeWidth: CGFloat) {
        let tick = radius * 0.4
        for (color, lineWidth) in passes(strokeWidth) {
            color.setStroke()

            let circle = NSBezierPath()
            circle.appendArc(
                withCenter: centre,
                radius: radius,
                startAngle: 0,
                endAngle: 360
            )
            circle.lineWidth = lineWidth
            circle.stroke()

            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: centre.x - tick, y: centre.y))
            cross.line(to: CGPoint(x: centre.x + tick, y: centre.y))
            cross.move(to: CGPoint(x: centre.x, y: centre.y - tick))
            cross.line(to: CGPoint(x: centre.x, y: centre.y + tick))
            cross.lineWidth = lineWidth
            cross.stroke()
        }
    }

    private static func rectangle(_ rect: CGRect, strokeWidth: CGFloat) {
        for (color, lineWidth) in passes(strokeWidth) {
            color.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = lineWidth
            path.stroke()
        }
    }

    /// Closed, so it reads as an enclosure rather than a line.
    private static func loop(_ points: [CGPoint], strokeWidth: CGFloat) {
        for (color, lineWidth) in passes(strokeWidth) {
            color.setStroke()
            let path = NSBezierPath()
            path.lineJoinStyle = .round
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.close()
            path.lineWidth = lineWidth
            path.stroke()
        }
    }

    /// Three concentric bands — white, then black, then magenta — so the mark
    /// has an edge against any background it can land on.
    ///
    /// It was two: a white surround under a magenta line, which covers a dark
    /// toolbar and leaves magenta alone to carry a light one. Two backgrounds
    /// defeat that. **A white or near-white page** hides the white band, leaving
    /// a magenta line whose only edge is against the page itself. **A magenta or
    /// hot-pink screen** — the case the colour was chosen to avoid, but a
    /// designer's canvas or a brand page is exactly where somebody points —
    /// leaves the magenta core with nothing to sit against. Black between them
    /// closes both: white always has an edge against black, black always has one
    /// against white, and the magenta core stays the thing the prompt refers to.
    ///
    /// Widths are multiples of the stroke so this scales with the image like
    /// everything else here. Drawn widest first, so each band is the rim of the
    /// one before it.
    ///
    /// **The outermost width is unchanged at 2.2.** Widening it to fit a third
    /// band was the obvious move and it was wrong: the mark's footprint grew
    /// inward and started covering the thing being pointed at, which
    /// `testTheMarkIsARingRatherThanADiscSoTheTargetStaysVisible` caught. The
    /// black is carved out of the white instead, so this costs no coverage at
    /// all — the hole in the middle of the ring is exactly as wide as it was.
    ///
    /// **Unverified against the model.** It cannot read worse than two bands —
    /// same magenta core, same footprint, strictly more edge — but whether it
    /// reads *better* is a question for repeated runs on the same screen with
    /// the wire dumps open, not for reasoning.
    private static func passes(_ strokeWidth: CGFloat) -> [(NSColor, CGFloat)] {
        [
            (outerColor, strokeWidth * 2.2),
            (midColor, strokeWidth * 1.6),
            (markColor, strokeWidth),
        ]
    }
}
