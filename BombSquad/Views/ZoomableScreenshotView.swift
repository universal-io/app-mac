import SwiftUI

/// Interactive screenshot preview: pinch/scroll-pinch to zoom, hand-tool drag
/// to pan, pen-tool drag to draw annotation rectangles, and an AI-provided
/// highlight box that auto-zooms into view (the "here it is" moment).
///
/// All geometry is anchored on normalized image coordinates (0-1, top-left
/// origin); the view only converts to screen points at draw time, so
/// annotations and highlights stay glued to the pixels they mark at any zoom.
struct ZoomableScreenshotView: View {
    /// The screenshot file. Loaded once per URL — the URL (not the NSImage
    /// instance) is the image's identity, so parent re-renders never reset
    /// the viewport mid-interaction or mid-highlight.
    let url: URL
    let tool: ScreenshotPreviewTool
    let annotationTint: ScreenshotAnnotation.Tint
    @Binding var annotations: [ScreenshotAnnotation]
    /// Normalized box the AI pointed at; setting it triggers an animated
    /// zoom-and-center so the user is taken to the spot.
    let highlight: CGRect?

    private static let maxZoom: CGFloat = 8

    @State private var image: NSImage?
    /// Committed zoom relative to aspect-fit (1 = whole image visible).
    @State private var zoom: CGFloat = 1
    /// Live pinch factor, applied on top of `zoom` during the gesture.
    @State private var pinch: CGFloat = 1
    /// Committed pan offset in view points.
    @State private var offset: CGSize = .zero
    /// Live drag translation while the hand tool is down.
    @State private var panTranslation: CGSize = .zero
    /// In-progress annotation rectangle (normalized) while the pen drags.
    @State private var draftRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let layout = layout(in: container)

            ZStack {
                // Catches gestures on the letterbox area too.
                Color.clear.contentShape(Rectangle())

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: layout.displaySize.width, height: layout.displaySize.height)
                        .position(x: layout.center.x, y: layout.center.y)
                }

                annotationOverlay(layout: layout)
                highlightOverlay(layout: layout)
            }
            .frame(width: container.width, height: container.height)
            .clipped()
            .gesture(dragGesture(in: container))
            .simultaneousGesture(magnifyGesture(in: container))
            .onTapGesture(count: 2) {
                withAnimation(.spring(duration: 0.3)) { resetViewport() }
            }
            .onChange(of: highlight) { _, box in
                guard let box else { return }
                withAnimation(.spring(duration: 0.55)) { zoomTo(box, in: container) }
            }
            .onAppear { loadImage() }
            .onChange(of: url) { _, _ in
                loadImage()
                resetViewport()
            }
        }
        .accessibilityLabel("スクリーンショットプレビュー")
    }

    private func loadImage() {
        image = NSImage(contentsOf: url)
    }

    // MARK: - Geometry

    private struct Layout {
        var displaySize: CGSize
        var center: CGPoint
    }

    private func layout(in container: CGSize) -> Layout {
        guard let imageSize = image?.size,
              imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return Layout(displaySize: .zero, center: .zero)
        }
        let fit = min(container.width / imageSize.width, container.height / imageSize.height)
        let scale = fit * zoom * pinch
        let display = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let pan = CGSize(
            width: offset.width + panTranslation.width,
            height: offset.height + panTranslation.height
        )
        let center = CGPoint(
            x: container.width / 2 + pan.width,
            y: container.height / 2 + pan.height
        )
        return Layout(displaySize: display, center: center)
    }

    private func viewRect(for normalized: CGRect, layout: Layout) -> CGRect {
        let imageBounds = imageRect(for: layout)
        return CGRect(
            x: imageBounds.minX + normalized.minX * layout.displaySize.width,
            y: imageBounds.minY + normalized.minY * layout.displaySize.height,
            width: normalized.width * layout.displaySize.width,
            height: normalized.height * layout.displaySize.height
        )
    }

    private func imageRect(for layout: Layout) -> CGRect {
        CGRect(
            x: layout.center.x - layout.displaySize.width / 2,
            y: layout.center.y - layout.displaySize.height / 2,
            width: layout.displaySize.width,
            height: layout.displaySize.height
        )
    }

    private func normalizedPoint(from viewPoint: CGPoint, layout: Layout) -> CGPoint {
        let origin = CGPoint(
            x: layout.center.x - layout.displaySize.width / 2,
            y: layout.center.y - layout.displaySize.height / 2
        )
        guard layout.displaySize.width > 0, layout.displaySize.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((viewPoint.x - origin.x) / layout.displaySize.width, 0), 1),
            y: min(max((viewPoint.y - origin.y) / layout.displaySize.height, 0), 1)
        )
    }

    // MARK: - Gestures

    private func dragGesture(in container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                switch tool {
                case .pan:
                    panTranslation = value.translation
                case .annotate:
                    let layout = layout(in: container)
                    let a = normalizedPoint(from: value.startLocation, layout: layout)
                    let b = normalizedPoint(from: value.location, layout: layout)
                    draftRect = CGRect(
                        x: min(a.x, b.x),
                        y: min(a.y, b.y),
                        width: abs(b.x - a.x),
                        height: abs(b.y - a.y)
                    )
                }
            }
            .onEnded { _ in
                switch tool {
                case .pan:
                    offset.width += panTranslation.width
                    offset.height += panTranslation.height
                    panTranslation = .zero
                    clampOffset(in: container)
                case .annotate:
                    if let rect = draftRect, rect.width > 0.01 || rect.height > 0.01 {
                        annotations.append(ScreenshotAnnotation(rect: rect, tint: annotationTint))
                    }
                    draftRect = nil
                }
            }
    }

    private func magnifyGesture(in container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                pinch = value.magnification
            }
            .onEnded { value in
                zoom = min(max(zoom * value.magnification, 1), Self.maxZoom)
                pinch = 1
                clampOffset(in: container)
            }
    }

    private func clampOffset(in container: CGSize) {
        let layout = layout(in: container)
        // Keep at least the image edge at the container edge; when the image
        // is smaller than the container on an axis it stays centered.
        let maxX = max(0, (layout.displaySize.width - container.width) / 2)
        let maxY = max(0, (layout.displaySize.height - container.height) / 2)
        withAnimation(.spring(duration: 0.25)) {
            offset.width = min(max(offset.width, -maxX), maxX)
            offset.height = min(max(offset.height, -maxY), maxY)
        }
    }

    private func resetViewport() {
        zoom = 1
        pinch = 1
        offset = .zero
        panTranslation = .zero
    }

    /// Centers the box and zooms so it fills ~55% of the container (capped so
    /// tiny boxes don't blow up into pixel soup).
    private func zoomTo(_ box: CGRect, in container: CGSize) {
        guard let imageSize = image?.size,
              imageSize.width > 0, imageSize.height > 0,
              box.width > 0, box.height > 0 else { return }
        let fit = min(container.width / imageSize.width, container.height / imageSize.height)
        let targetZoom = min(
            0.55 * min(
                container.width / (box.width * imageSize.width * fit),
                container.height / (box.height * imageSize.height * fit)
            ),
            5
        )
        zoom = max(1, targetZoom)
        let display = CGSize(width: imageSize.width * fit * zoom, height: imageSize.height * fit * zoom)
        offset = CGSize(
            width: -(box.midX - 0.5) * display.width,
            height: -(box.midY - 0.5) * display.height
        )
        let maxX = max(0, (display.width - container.width) / 2)
        let maxY = max(0, (display.height - container.height) / 2)
        offset.width = min(max(offset.width, -maxX), maxX)
        offset.height = min(max(offset.height, -maxY), maxY)
    }

    // MARK: - Overlays

    @ViewBuilder
    private func annotationOverlay(layout: Layout) -> some View {
        ForEach(annotations) { annotation in
            let rect = viewRect(for: annotation.rect, layout: layout)
            Rectangle()
                .strokeBorder(annotation.tint.color, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
        if let draft = draftRect {
            let rect = viewRect(for: draft, layout: layout)
            Rectangle()
                .strokeBorder(annotationTint.color, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                .background(annotationTint.color.opacity(0.08))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func highlightOverlay(layout: Layout) -> some View {
        if let highlight {
            let target = viewRect(for: highlight, layout: layout)
            let safeImageBounds = imageRect(for: layout).insetBy(dx: 7, dy: 7)
            let rect = target
                .insetBy(dx: -6, dy: -4)
                .intersection(safeImageBounds)
            if !rect.isNull, rect.width > 0, rect.height > 0 {
                RoundedRectangle(cornerRadius: min(8, rect.height / 4))
                    .strokeBorder(Color.red, lineWidth: 3)
                    .shadow(color: .red.opacity(0.55), radius: 4)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 1.15)))
            }
        }
    }
}
