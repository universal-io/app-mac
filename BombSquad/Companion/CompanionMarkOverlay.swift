import AppKit

/// R18 V2: the companion's mark on the real screen — the frame around the
/// thing the voice is talking about.
///
/// Not `VisionPointingOverlay`. That surface sweeps a wash over the screen,
/// makes its bubble key — which takes the keyboard from the app the user is
/// working in — and is closed whenever `AppMode` goes back to idle, which is
/// where the companion lives. This is the smallest thing that can carry the
/// same mark: one click-through window over the captured screen, holding
/// `MarkStyle` layers and nothing else, so a frame here and a frame in Vision
/// are the same claim drawn the same way.
///
/// It never becomes key (a borderless window cannot) and never activates this
/// app (`orderFrontRegardless`). Like every window of this app it is left out
/// of the screenshots the eye reads — `ScreenshotCaptureService` excludes this
/// process from its filter — and out of the voice layer's feed
/// (`CompanionScreenFeed`, the same exclusion), so the model never reads its
/// own mark back.
@MainActor
final class CompanionMarkOverlay {
    /// Whether a mark is on screen now.
    private(set) var isShowing = false

    private var window: OverlayWindow?
    private var marks: [CALayer] = []

    /// Puts up one frame per rectangle and takes down whatever was up before.
    ///
    /// `rects` are normalized (0...1, top-left origin) within `captureRect`
    /// (CG global coordinates), as `VisionSession` uses them.
    func show(_ rects: [CGRect], captureRect: CGRect, displayID: CGDirectDisplayID?) {
        guard !rects.isEmpty, captureRect.width > 0, captureRect.height > 0,
              let screen = Self.screen(showing: captureRect, preferring: displayID)
        else {
            clear()
            return
        }
        let window = self.window ?? Self.makeWindow()
        self.window = window
        window.cover(screen)
        guard let host = window.contentView?.layer else {
            clear()
            return
        }
        let mainDisplayHeight = VisionPointerResolver.mainDisplayHeight
        // A new mark replaces the old one whole, with no implicit fade or
        // slide: a frame drifting across the screen would point at everything
        // it passes over on the way.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marks.forEach { $0.removeFromSuperlayer() }
        marks = rects.map { rect in
            let local = VisionPointerResolver.screenLocalRect(
                normalized: rect,
                captureRect: captureRect,
                mainDisplayHeight: mainDisplayHeight,
                screenFrame: screen.frame
            )
            let mark = MarkStyle.layer(for: .frame(local))
            Self.render(mark, at: screen.backingScaleFactor)
            host.addSublayer(mark)
            return mark
        }
        CATransaction.commit()
        window.orderFrontRegardless()
        isShowing = true
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marks.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        marks = []
        window?.orderOut(nil)
        isShowing = false
    }

    private static func makeWindow() -> OverlayWindow {
        let window = OverlayWindow(clickThrough: true)
        window.contentView = MarkCanvas(frame: .zero)
        return window
    }

    /// The screen the capture was taken of, because the rectangles are
    /// fractions of it. `displayID` decides only when the capture's own
    /// rectangle does not: a capture whose display went away falls back to
    /// another one (`ScreenshotCaptureService`), and a frame drawn on the
    /// requested display would then be a whole screen off.
    private static func screen(
        showing captureRect: CGRect,
        preferring displayID: CGDirectDisplayID?
    ) -> NSScreen? {
        let centre = CGPoint(x: captureRect.midX, y: captureRect.midY)
        let screens = NSScreen.screens
        if let captured = screens.first(where: { screen in
            guard let id = ActiveDisplay.displayID(of: screen) else { return false }
            return CGDisplayBounds(id).contains(centre)
        }) {
            return captured
        }
        return screens.first { ActiveDisplay.displayID(of: $0) == displayID } ?? NSScreen.main
    }

    /// Layers added by hand are not given the screen's scale by AppKit, and a
    /// 2.5pt line rasterized at 1x reads as a smudge on a Retina display.
    private static func render(_ layer: CALayer, at scale: CGFloat) {
        layer.contentsScale = scale
        layer.sublayers?.forEach { render($0, at: scale) }
    }
}

/// Holds the mark layers. Transparent to the mouse as well as the window
/// being click-through: the screen under it belongs to the user's app.
private final class MarkCanvas: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
