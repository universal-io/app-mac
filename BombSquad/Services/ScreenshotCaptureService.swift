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
    func captureMatchingScope(of attachment: ScreenshotAttachment) async throws -> ScreenshotAttachment {
        let displayID = Self.displayID(containing: attachment.captureRect)
        guard attachment.captureScope == .region,
              let globalRect = attachment.captureRect else {
            return try await captureFullScreen(displayID: displayID)
        }
        let bounds = CGDisplayBounds(displayID)
        let localRect = CGRect(
            x: globalRect.minX - bounds.minX,
            y: bounds.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
        return try await captureRegion(localRect, displayID: displayID)
    }

    /// Capture the whole screen the user is looking at — the "just summon it"
    /// path of the North Star flow: the model sees exactly what the user sees.
    /// Universal I/O's own windows are excluded from the captured display so
    /// a copilot progress shot cannot feed its previous instruction back into
    /// the model. Throws `noCaptureTarget` when no display can be resolved.
    func captureFullScreen(displayID: CGDirectDisplayID?) async throws -> ScreenshotAttachment {
        let (image, _, resolvedID) = try await captureDisplayImage(displayID: displayID)
        return try Self.writeAttachment(
            image,
            captureScope: .display,
            captureRect: CGDisplayBounds(resolvedID)
        )
    }

    /// Capture a region of the display, given in screen-local points with a
    /// bottom-left origin (as reported by the selection overlay).
    func captureRegion(_ rect: CGRect, displayID: CGDirectDisplayID?) async throws -> ScreenshotAttachment {
        let (image, displaySize, resolvedID) = try await captureDisplayImage(displayID: displayID)
        // The shot may be downscaled (5K budget), so derive the point→pixel
        // ratio from the image itself, and flip to CGImage's top-left origin.
        let scaleX = CGFloat(image.width) / displaySize.width
        let scaleY = CGFloat(image.height) / displaySize.height
        let pixelRect = CGRect(
            x: rect.minX * scaleX,
            y: (displaySize.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = image.cropping(to: pixelRect)
        else {
            throw ScreenshotCaptureError.noCaptureTarget
        }
        // Same flip, but into global display coordinates (CG top-left).
        let displayBounds = CGDisplayBounds(resolvedID)
        let globalRect = CGRect(
            x: displayBounds.minX + rect.minX,
            y: displayBounds.minY + (displaySize.height - rect.maxY),
            width: rect.width,
            height: rect.height
        )
        return try Self.writeAttachment(cropped, captureScope: .region, captureRect: globalRect)
    }

    private func captureDisplayImage(
        displayID: CGDirectDisplayID?
    ) async throws -> (image: CGImage, displaySize: CGSize, displayID: CGDirectDisplayID) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
        else {
            throw ScreenshotCaptureError.noCaptureTarget
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let ownApplications = content.applications.filter {
            $0.processID == ownProcessID
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var width = Int(CGFloat(display.width) * scale)
        var height = Int(CGFloat(display.height) * scale)
        // 5K-class displays produce shots past the gateway's upload budget
        // even as JPEG; half resolution still reads fine for interpretation.
        if max(width, height) > 4096 {
            width /= 2
            height /= 2
        }
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )
        return (image, CGSize(width: display.width, height: display.height), display.displayID)
    }

    private static func displayID(containing rect: CGRect?) -> CGDirectDisplayID {
        guard let rect else { return CGMainDisplayID() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            return CGMainDisplayID()
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return CGMainDisplayID()
        }
        return displays.first { CGDisplayBounds($0).contains(center) } ?? CGMainDisplayID()
    }

    private static func writeAttachment(
        _ image: CGImage,
        captureScope: ScreenshotCaptureScope,
        captureRect: CGRect?
    ) throws -> ScreenshotAttachment {
        let outputURL = try makeCaptureOutputURL()
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw ScreenshotCaptureError.outputMissing
        }
        try png.write(to: outputURL)

        return ScreenshotAttachment(
            url: outputURL,
            pixelWidth: image.width,
            pixelHeight: image.height,
            captureScope: captureScope,
            captureRect: captureRect
        )
    }

    func captureInteractive() async throws -> ScreenshotAttachment {
        let outputURL = try Self.makeCaptureOutputURL()
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
                        pixelHeight: size?.height,
                        captureScope: .unknown
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Captures live in the temporary directory: they exist for the session
    /// (preview, wire upload, explicit save). Nothing lands on the Desktop
    /// unless the user presses the save button and picks a location.
    private static func makeCaptureOutputURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniversalIO-Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Multiple progress checks can land within one second. A unique suffix
        // prevents a newer capture from overwriting a still-preparing older URL.
        let unique = UUID().uuidString.prefix(8)
        let fileName = "Universal-IO-\(Self.fileTimestamp())-\(unique).png"
        return directory.appendingPathComponent(fileName)
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

enum StableScreenCaptureOutcome {
    case stable(ScreenshotAttachment)
    case timedOut
}

enum StableScreenCaptureService {
    private static let sampleDelayNanoseconds: UInt64 = 350_000_000
    private static let maxAttempts = 8
    private static let changeThreshold = 0.015
    private static let stableThreshold = 0.003
    private static let comparisonSide = 48

    static func capture(after baseline: ScreenshotAttachment) async throws -> StableScreenCaptureOutcome {
        let captureService = ScreenshotCaptureService()
        var latestCapture: ScreenshotAttachment?
        var changeDetected = false
        defer {
            if let latestCapture { remove(latestCapture) }
        }

        for attempt in 0..<maxAttempts {
            let current = try await captureService.captureMatchingScope(of: baseline)
            if Task.isCancelled {
                remove(current)
                throw CancellationError()
            }

            if !changeDetected {
                let difference = await differenceRatio(baseline.url, current.url)
                if difference >= changeThreshold {
                    changeDetected = true
                    latestCapture = current
                } else {
                    remove(current)
                }
            } else if let previous = latestCapture {
                let difference = await differenceRatio(previous.url, current.url)
                if difference <= stableThreshold {
                    remove(previous)
                    return .stable(current)
                }
                remove(previous)
                latestCapture = current
            }

            if attempt < maxAttempts - 1 {
                try await Task.sleep(nanoseconds: sampleDelayNanoseconds)
            }
        }

        return .timedOut
    }

    private static func differenceRatio(_ lhs: URL, _ rhs: URL) async -> Double {
        await Task.detached(priority: .utility) {
            guard let left = grayscalePixels(at: lhs),
                  let right = grayscalePixels(at: rhs),
                  left.count == right.count,
                  !left.isEmpty else { return 1 }
            let total = zip(left, right).reduce(0) {
                $0 + abs(Int($1.0) - Int($1.1))
            }
            return Double(total) / Double(left.count * 255)
        }.value
    }

    private static func grayscalePixels(at url: URL) -> [UInt8]? {
        guard let data = try? Data(contentsOf: url),
              let source = NSBitmapImageRep(data: data),
              let image = source.cgImage,
              let context = CGContext(
                data: nil,
                width: comparisonSide,
                height: comparisonSide,
                bitsPerComponent: 8,
                bytesPerRow: comparisonSide,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: comparisonSide, height: comparisonSide))
        guard let buffer = context.data else { return nil }
        let pointer = buffer.bindMemory(to: UInt8.self, capacity: comparisonSide * comparisonSide)
        return Array(UnsafeBufferPointer(start: pointer, count: comparisonSide * comparisonSide))
    }

    private static func remove(_ attachment: ScreenshotAttachment) {
        try? FileManager.default.removeItem(at: attachment.url)
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
