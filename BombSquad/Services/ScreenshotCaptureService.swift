import AppKit
import Foundation
import ScreenCaptureKit

enum ScreenshotCaptureError: LocalizedError {
    case cancelled
    case desktopUnavailable
    case failed(status: Int32)
    case outputMissing
    case noCaptureTarget

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "スクリーンショットをキャンセルしました。"
        case .desktopUnavailable:
            return "デスクトップの保存先を取得できませんでした。"
        case .failed(let status):
            return "スクリーンショットの撮影に失敗しました（終了コード: \(status)）。"
        case .outputMissing:
            return "スクリーンショットファイルを作成できませんでした。"
        case .noCaptureTarget:
            return "撮影対象のウィンドウが見つかりませんでした。"
        }
    }
}

struct ScreenshotCaptureService {
    /// Capture the frontmost regular window of `app` without any user
    /// interaction — the "just summon it" path of the North Star flow. The
    /// panel is not part of the shot because the filter targets that window
    /// alone. Throws `noCaptureTarget` when the app has no capturable window
    /// (the caller falls back to interactive selection).
    func captureFrontWindow(of app: NSRunningApplication) async throws -> ScreenshotAttachment {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        // Shareable windows come front-to-back; layer 0 skips menu bar and
        // status items, the size floor skips zero-sized helper windows.
        guard let window = content.windows.first(where: { window in
            window.owningApplication?.processID == app.processIdentifier
                && window.windowLayer == 0
                && window.frame.width >= 120 && window.frame.height >= 90
        }) else {
            throw ScreenshotCaptureError.noCaptureTarget
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )

        let outputURL = try Self.makeDesktopOutputURL()
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw ScreenshotCaptureError.outputMissing
        }
        try png.write(to: outputURL)

        return ScreenshotAttachment(
            url: outputURL,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    func captureInteractive() async throws -> ScreenshotAttachment {
        let outputURL = try Self.makeDesktopOutputURL()
        try? FileManager.default.removeItem(at: outputURL)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", outputURL.path]

                do {
                    try process.run()
                    process.waitUntilExit()

                    guard process.terminationStatus == 0 else {
                        if !FileManager.default.fileExists(atPath: outputURL.path) {
                            continuation.resume(throwing: ScreenshotCaptureError.cancelled)
                        } else {
                            continuation.resume(throwing: ScreenshotCaptureError.failed(status: process.terminationStatus))
                        }
                        return
                    }

                    guard Self.hasNonEmptyFile(at: outputURL) else {
                        continuation.resume(throwing: ScreenshotCaptureError.outputMissing)
                        return
                    }

                    let size = Self.imagePixelSize(at: outputURL)
                    continuation.resume(returning: ScreenshotAttachment(
                        url: outputURL,
                        pixelWidth: size?.width,
                        pixelHeight: size?.height
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makeDesktopOutputURL() throws -> URL {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw ScreenshotCaptureError.desktopUnavailable
        }
        let fileName = "BombSquad-\(Self.fileTimestamp()).png"
        return desktop.appendingPathComponent(fileName)
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func hasNonEmptyFile(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    private static func imagePixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let image = NSImage(contentsOf: url),
              let representation = image.representations.first
        else { return nil }
        return (representation.pixelsWide, representation.pixelsHigh)
    }
}

final class ScreenshotCaptureCuePresenter {
    private var windows: [NSWindow] = []

    @MainActor
    func showBriefly() async {
        show()
        try? await Task.sleep(nanoseconds: 700_000_000)
        hide()
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    @MainActor
    private func show() {
        hide()
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = ScreenshotCaptureCueView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.orderFrontRegardless()
            return window
        }
    }

    @MainActor
    private func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class ScreenshotCaptureCueView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.black.withAlphaComponent(0.36).setFill()
        bounds.fill()

        drawFrameMarks()
        drawInstructionPill()
    }

    private func drawFrameMarks() {
        let inset: CGFloat = 34
        let length: CGFloat = 62
        let lineWidth: CGFloat = 4
        let rect = bounds.insetBy(dx: inset, dy: inset)

        let path = NSBezierPath()
        path.lineWidth = lineWidth
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
        let title = "範囲を選択"
        let subtitle = "読み取りたい領域をドラッグしてください"
        let maxWidth = min(bounds.width - 80, 420)
        let pillRect = NSRect(
            x: bounds.midX - maxWidth / 2,
            y: bounds.midY - 42,
            width: maxWidth,
            height: 84
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

        drawCentered(title, in: NSRect(x: pillRect.minX + 20, y: pillRect.midY + 4, width: pillRect.width - 40, height: 24), attributes: titleAttributes)
        drawCentered(subtitle, in: NSRect(x: pillRect.minX + 20, y: pillRect.midY - 24, width: pillRect.width - 40, height: 20), attributes: subtitleAttributes)
    }

    private func drawCentered(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
