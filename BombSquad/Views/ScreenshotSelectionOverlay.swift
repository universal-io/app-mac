import AppKit

/// Vision capture entry (owner spec, 2026-07-03): summoning on an empty draft
/// opens this overlay with the whole screen pre-selected. Enter confirms the
/// full screen, dragging captures a region instead (the pre-M4 behavior),
/// Esc closes the session. A right-Shift double-tap is detected outside
/// (AppDelegate) and abandons the whole session back to standby.
final class ScreenshotSelectionOverlay {
    enum Outcome {
        case fullScreen
        /// Screen-local points, bottom-left origin (the overlay covers one screen).
        case region(CGRect)
        case cancelled
    }

    private var window: NSWindow?
    private var continuation: CheckedContinuation<Outcome, Never>?

    @MainActor
    var isPresenting: Bool { window != nil }

    @MainActor
    func present(on screen: NSScreen) async -> Outcome {
        finish(.cancelled) // never allow two concurrent sessions

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            let window = KeyableOverlayWindow(clickThrough: false)
            window.cover(screen)

            let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onOutcome = { [weak self] outcome in
                MainActor.assumeIsolated { self?.finish(outcome) }
            }
            window.contentView = view

            self.window = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
    }

    /// Abandon from outside (right-Shift double-tap while selecting).
    @MainActor
    func cancel() { finish(.cancelled) }

    @MainActor
    private func finish(_ outcome: Outcome) {
        window?.orderOut(nil)
        window = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }
}

private final class SelectionOverlayView: NSView {
    var onOutcome: ((ScreenshotSelectionOverlay.Outcome) -> Void)?

    private var dragStart: NSPoint?
    private var selectionRect: NSRect? {
        didSet { needsDisplay = true }
    }
    /// Drags shorter than this are clicks; the full screen stays selected.
    private let minimumDragSize: CGFloat = 8

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter: confirm the full-screen selection
            onOutcome?(.fullScreen)
        case 53: // Esc: close the session
            onOutcome?(.cancelled)
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selectionRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(
            x: min(dragStart.x, point.x),
            y: min(dragStart.y, point.y),
            width: abs(point.x - dragStart.x),
            height: abs(point.y - dragStart.y)
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let rect = selectionRect,
              rect.width >= minimumDragSize, rect.height >= minimumDragSize
        else {
            selectionRect = nil // a plain click: keep the full screen selected
            return
        }
        onOutcome?(.region(rect))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let rect = selectionRect {
            NSColor.black.withAlphaComponent(0.45).setFill()
            let dimmed = NSBezierPath(rect: bounds)
            dimmed.append(NSBezierPath(rect: rect))
            dimmed.windingRule = .evenOdd
            dimmed.fill()

            let border = NSBezierPath(rect: rect)
            border.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            border.stroke()
        } else {
            NSColor.black.withAlphaComponent(0.22).setFill()
            bounds.fill()
            drawFrameMarks()
            drawInstructionPill()
        }
    }

    private func drawFrameMarks() {
        let inset: CGFloat = 34
        let length: CGFloat = 62
        let rect = bounds.insetBy(dx: inset, dy: inset)

        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        path.move(to: NSPoint(x: rect.minX, y: rect.minY + length))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: NSPoint(x: rect.maxX - length, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: NSPoint(x: rect.maxX, y: rect.maxY - length))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX - length, y: rect.maxY))

        path.move(to: NSPoint(x: rect.minX + length, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - length))

        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func drawInstructionPill() {
        let title = "全画面が選択されています"
        let line1 = "Enter でこのまま読み取り ／ ドラッグで範囲を選択"
        let line2 = "esc で閉じる ・ \(KeybindingSettings.gestureKey().hintLabel) 2回で閉じる"
        let maxWidth = min(bounds.width - 80, 460)
        let pillRect = NSRect(
            x: bounds.midX - maxWidth / 2,
            y: bounds.midY - 52,
            width: maxWidth,
            height: 104
        )

        let background = NSBezierPath(roundedRect: pillRect, xRadius: 14, yRadius: 14)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        background.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
        background.lineWidth = 1
        background.stroke()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        drawCentered(title, in: NSRect(x: pillRect.minX + 20, y: pillRect.midY + 16, width: pillRect.width - 40, height: 24), attributes: titleAttributes)
        drawCentered(line1, in: NSRect(x: pillRect.minX + 20, y: pillRect.midY - 10, width: pillRect.width - 40, height: 20), attributes: subtitleAttributes)
        drawCentered(line2, in: NSRect(x: pillRect.minX + 20, y: pillRect.midY - 32, width: pillRect.width - 40, height: 20), attributes: subtitleAttributes)
    }

    private func drawCentered(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
