import SwiftUI

/// Interactive screenshot preview: pinch/scroll-pinch to zoom, hand-tool drag
/// to pan, pen-tool drag to draw annotation rectangles, and a provided
/// highlight box that auto-zooms into view.
///
/// All geometry is anchored on normalized image coordinates (0-1, top-left
/// origin); the view only converts to screen points at draw time, so
/// annotations and highlights stay glued to the pixels they mark at any zoom.
struct ZoomableScreenshotView: View {
    /// The already-resolved screenshot. This view renders pixels; it does not
    /// fetch them. Reading the file from `.onAppear` made the panel's contents
    /// depend on an appearance callback, and on 2026-08-03 that callback did
    /// not arrive: the panel opened with no image and no explanation
    /// (docs/reliability-hardening-plan.md D3).
    let image: NSImage?
    /// Identity of the capture being shown — `nil` while none is resolved.
    /// Viewport state resets when this changes, never when the parent merely
    /// re-renders, so a zoom survives mid-interaction and mid-highlight.
    let imageID: UUID?
    let tool: ScreenshotPreviewTool
    let annotationTint: ScreenshotAnnotation.Tint
    @Binding var annotations: [ScreenshotAnnotation]
    /// Normalized box the AI pointed at; setting it triggers an animated
    /// zoom-and-center so the user is taken to the spot.
    let highlight: CGRect?
    let highlightTint: Color
    let highlightLabel: String?
    /// All capture-visible Selection Extension frames. These are drawn as
    /// separate boxes and never collapsed into a single representative box.
    let selectionHighlights: [CGRect]

    private static let maxZoom: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// Committed zoom relative to aspect-fit (1 = whole image visible).
    @State private var zoom: CGFloat = 1
    /// Live pinch factor, applied on top of `zoom` during the gesture.
    @State private var pinch: CGFloat = 1
    /// Committed pan offset in view points.
    @State private var offset: CGSize = .zero
    /// Live drag translation while the hand tool is down.
    @State private var panTranslation: CGSize = .zero
    /// Drives the grab cursor while the screenshot itself is being moved.
    @State private var isPanning = false
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
                selectionHighlightOverlay(layout: layout)
                highlightOverlay(layout: layout)
            }
            .frame(width: container.width, height: container.height)
            .clipped()
            .overlay {
                ScreenshotPanCursor(cursor: isPanning ? .closedHand : .openHand)
                    .allowsHitTesting(false)
            }
            .gesture(dragGesture(in: container))
            .simultaneousGesture(magnifyGesture(in: container))
            .onTapGesture(count: 2) {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) {
                    resetViewport()
                }
            }
            .onChange(of: highlight) { _, box in
                guard let box else { return }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.55)) {
                    zoomTo(box, in: container)
                }
            }
            .onChange(of: imageID) { _, _ in resetViewport() }
        }
        .accessibilityLabel("スクリーンショットプレビュー")
        .accessibilityValue(
            accessibilityHighlightSummary
        )
    }

    private var accessibilityHighlightSummary: String {
        var parts: [String] = []
        if !selectionHighlights.isEmpty {
            parts.append("選択範囲を\(selectionHighlights.count)か所に枠で表示")
        }
        if highlight != nil {
            parts.append("\(highlightLabel ?? "案内位置")を枠で表示")
        }
        return parts.isEmpty ? "ハイライトなし" : parts.joined(separator: "、")
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
                    isPanning = true
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
                    isPanning = false
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
        withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) {
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
    private func selectionHighlightOverlay(layout: Layout) -> some View {
        ForEach(Array(selectionHighlights.enumerated()), id: \.offset) { index, highlight in
            let target = viewRect(for: highlight, layout: layout)
            let safeImageBounds = imageRect(for: layout).insetBy(dx: 7, dy: 7)
            let rect = target
                .insetBy(dx: -4, dy: -3)
                .intersection(safeImageBounds)
            if !rect.isNull, rect.width > 0, rect.height > 0 {
                RoundedRectangle(cornerRadius: min(8, rect.height / 4))
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(
                            lineWidth: colorSchemeContrast == .increased ? 5 : 3,
                            dash: [8, 4]
                        )
                    )
                    .background(
                        reduceTransparency ? Color.clear : Color.accentColor.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: min(8, rect.height / 4))
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)

                if index == 0 {
                    let label = selectionHighlights.count == 1
                        ? "選択範囲"
                        : "選択範囲（\(selectionHighlights.count)か所）"
                    highlightCaption(
                        label,
                        rect: rect,
                        safeImageBounds: safeImageBounds,
                        tint: .accentColor
                    )
                }
            }
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
                    .strokeBorder(
                        highlightTint,
                        lineWidth: colorSchemeContrast == .increased ? 5 : 3
                    )
                    .shadow(
                        color: colorSchemeContrast == .increased
                            ? .clear
                            : highlightTint.opacity(0.55),
                        radius: 4
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 1.15))
                    )
                if let highlightLabel {
                    highlightCaption(
                        highlightLabel,
                        rect: rect,
                        safeImageBounds: safeImageBounds,
                        tint: highlightTint
                    )
                }
            }
        }
    }

    private func highlightCaption(
        _ text: String,
        rect: CGRect,
        safeImageBounds: CGRect,
        tint: Color
    ) -> some View {
        let labelX = min(
            max(rect.midX, safeImageBounds.minX + 40),
            safeImageBounds.maxX - 40
        )
        let preferredY = rect.minY - 12
        let labelY = preferredY >= safeImageBounds.minY + 10
            ? preferredY
            : min(rect.maxY + 12, safeImageBounds.maxY - 10)
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.primary)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                reduceTransparency
                    ? Color(nsColor: .windowBackgroundColor)
                    : Color(nsColor: .controlBackgroundColor),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        tint,
                        lineWidth: colorSchemeContrast == .increased ? 2 : 1
                    )
            }
            .position(x: labelX, y: labelY)
            .allowsHitTesting(false)
    }
}

/// Cursor rectangles are the reliable macOS way to advertise direct
/// manipulation without adding a separate hand-tool control to the UI.
private struct ScreenshotPanCursor: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorView {
        CursorView(cursor: cursor)
    }

    func updateNSView(_ nsView: CursorView, context: Context) {
        nsView.cursor = cursor
    }

    final class CursorView: NSView {
        private var previousWindowBackgroundDragging: Bool?

        var cursor: NSCursor {
            didSet {
                guard oldValue != cursor else { return }
                window?.invalidateCursorRects(for: self)
            }
        }

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            guard previousWindowBackgroundDragging == nil, let window else { return }
            previousWindowBackgroundDragging = window.isMovableByWindowBackground
            // The borderless panel normally moves from empty background.
            // While the pointer is over the screenshot, its drag gesture owns
            // the same mouse event and must pan the image instead.
            window.isMovableByWindowBackground = false
        }

        override func mouseExited(with event: NSEvent) {
            restoreWindowBackgroundDragging()
            super.mouseExited(with: event)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window {
                restoreWindowBackgroundDragging()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        private func restoreWindowBackgroundDragging() {
            guard let previousWindowBackgroundDragging else { return }
            window?.isMovableByWindowBackground = previousWindowBackgroundDragging
            self.previousWindowBackgroundDragging = nil
        }
    }
}
