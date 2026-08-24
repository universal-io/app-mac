import AppKit
import Foundation
import ScreenCaptureKit

enum ScreenshotCaptureError: UserPresentableError {
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
    private static let temporaryDirectoryName = "UniversalIO-Captures"
    private static let temporaryFilePrefix = "Universal-IO-"

    /// Removes captures left by a prior session or abnormal termination.
    /// Only files created by this app inside its dedicated temporary folder
    /// are eligible; unrelated temporary data is never touched.
    static func cleanupTemporaryCaptures(fileManager: FileManager = .default) {
        let directory = temporaryCaptureDirectory(fileManager: fileManager)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(temporaryFilePrefix) {
            try? fileManager.removeItem(at: file)
        }
    }

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
        if let displayID, display.displayID != displayID {
            // Capturing a different display than requested (display unplugged
            // or SCK enumeration mismatch) must never be silent.
            NSLog(
                "Vision capture display fallback: requested=%u using=%u",
                displayID, display.displayID
            )
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
        // An empty exclusion list means the filter excludes nothing, and every
        // overlay this app draws lands in the shot it is meant to be absent
        // from. Nothing throws when that happens, so the count is recorded and
        // a zero is the thing to look for.
        let excludedCount = ownApplications.count
        let menuWasOpen = Self.nativeMenuIsOpen()
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

        let startedAt = Date()
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )
        // How long one shot costs, which nothing recorded until now.
        //
        // The number decides a design question rather than merely describing
        // one: pointing takes a fresh still at the moment of each gesture, and
        // whether that is affordable — or whether an unchanged screen has to be
        // reused instead — depends on this against a Gateway round trip
        // (docs/universal-io-master-plan.md R14「設計の芯」).
        Diagnostics.record("capture.display", details: [
            ("ms", .ms(Int(Date().timeIntervalSince(startedAt) * 1000))),
            ("px", .count(width * height / 1000)),
            ("excluded", .count(excludedCount)),
            ("menu", .flag(menuWasOpen)),
            // Which display this shot is of. Pointing re-captures derive the
            // display from the original attachment's rect while the overlay
            // covers `ActiveDisplay.screen()` — on a two-display machine those
            // can in principle disagree, and every coordinate downstream would
            // be off by a whole screen. This makes that case visible.
            ("display", .count(Int(display.displayID))),
        ])
        return (image, CGSize(width: display.width, height: display.height), display.displayID)
    }

    /// Whether a native menu was open at the moment of the shot.
    ///
    /// A macOS menu is its own window at the pop-up menu level; a web page's
    /// dropdown is drawn inside the browser window and has no window of its
    /// own. So this single flag separates the two cases, and it answers a
    /// question a staged experiment could not: whether the screens people
    /// actually point at have native menus open on them, and whether those
    /// menus are still there once our overlay appears. Real use fills this in
    /// without anyone having to hold a menu open on cue.
    ///
    /// Only the window level is read. Owner names and titles are available here
    /// and are deliberately not taken — `DiagnosticValue` could not carry them
    /// anyway (README「データ保存」).
    private static func nativeMenuIsOpen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windows.contains {
            ($0[kCGWindowLayer as String] as? Int) == popUpMenuLevel
        }
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
                        let outputExists = FileManager.default.fileExists(atPath: outputURL.path)
                        try? FileManager.default.removeItem(at: outputURL)
                        if !outputExists {
                            continuation.resume(throwing: ScreenshotCaptureError.cancelled)
                        } else {
                            continuation.resume(throwing: ScreenshotCaptureError.failed(status: process.terminationStatus))
                        }
                        return
                    }

                    guard Self.hasNonEmptyFile(at: outputURL) else {
                        try? FileManager.default.removeItem(at: outputURL)
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
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Captures live only in the app's temporary directory for the active
    /// Vision session. Session teardown removes the current capture and app
    /// launch removes anything left by an abnormal termination.
    private static func makeCaptureOutputURL() throws -> URL {
        let directory = temporaryCaptureDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Multiple progress checks can land within one second. A unique suffix
        // prevents a newer capture from overwriting a still-preparing older URL.
        let unique = UUID().uuidString.prefix(8)
        let fileName = "Universal-IO-\(Self.fileTimestamp())-\(unique).png"
        return directory.appendingPathComponent(fileName)
    }

    private static func temporaryCaptureDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(temporaryDirectoryName, isDirectory: true)
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

/// A progress capture is always produced — the user's action is direct
/// evidence and pixel differencing has no veto over it. Differencing only
/// *times* the shot (shoot once the change settles) and annotates it.
struct StableScreenCaptureResult {
    let attachment: ScreenshotAttachment
    /// False: the screen looked identical to the baseline for the whole
    /// watch window despite the user's action — shown to the user as an
    /// honest note alongside the (likely repeated) guidance.
    let changeObserved: Bool
    /// False: the screen was still changing when the window closed
    /// (animation, slow load); the freshest frame was adopted anyway.
    let settled: Bool
    /// How many screenshots this watch window took before adopting one. The
    /// user waits through every one of them plus the delay between them, so a
    /// copilot step that felt slow is explained by this number more often than
    /// by the model. The no-change path spends the full budget by construction.
    let attempts: Int
}

enum StableScreenCaptureService {
    private static let sampleDelayNanoseconds: UInt64 = 350_000_000
    private static let maxAttempts = 8
    /// Change is judged per block, not on the whole-screen mean: a submenu
    /// expanding changes <0.5% of a large display, which a global mean can
    /// never separate from noise (measured on the GA4 sidebar click: global
    /// mean 0.002 vs the old 0.015 gate — 7.5x too small — while its blockMax
    /// is ~0.085). The JPEG/scaling noise floor measured 0.0015, so 0.05
    /// keeps a wide margin on both sides.
    private static let changeBlockThreshold = 0.05
    private static let stableThreshold = 0.003
    private static let comparisonSide = 48
    private static let blockGrid = 12

    /// Watches for the click's effect and returns the best capture the
    /// window allows: settled-after-change when possible, the identical
    /// screen when nothing changed, the freshest frame when the screen never
    /// stopped moving. It always returns a capture — shooting too much is
    /// acceptable, not shooting is not.
    /// `waitForChange: false` (manual 再確認) skips the change phase.
    static func capture(
        after baseline: ScreenshotAttachment,
        waitForChange: Bool = true
    ) async throws -> StableScreenCaptureResult {
        let captureService = ScreenshotCaptureService()
        var latestCapture: ScreenshotAttachment?
        var changeDetected = !waitForChange
        var observedChange = false
        var succeeded = false
        defer {
            if !succeeded, let latestCapture { remove(latestCapture) }
        }

        for attempt in 0..<maxAttempts {
            let current = try await captureService.captureMatchingScope(of: baseline)
            if Task.isCancelled {
                remove(current)
                throw CancellationError()
            }

            if !changeDetected {
                let difference = await differences(baseline.url, current.url)
                log(attempt: attempt, phase: "change", difference: difference.blockMax)
                if difference.blockMax >= changeBlockThreshold {
                    changeDetected = true
                    observedChange = true
                    latestCapture = current
                } else if attempt == maxAttempts - 1 {
                    // No visible change in the whole window: the screen is by
                    // definition settled. Hand the model this capture rather
                    // than overruling the user's action.
                    log(attempt: attempt, phase: "no_change_adopt", difference: nil)
                    succeeded = true
                    return StableScreenCaptureResult(
                        attachment: current,
                        changeObserved: false,
                        settled: true,
                        attempts: attempt + 1
                    )
                } else {
                    remove(current)
                }
            } else if let previous = latestCapture {
                let difference = await differences(previous.url, current.url)
                log(attempt: attempt, phase: "stability", difference: difference.mean)
                remove(previous)
                latestCapture = current
                if difference.mean <= stableThreshold {
                    succeeded = true
                    return StableScreenCaptureResult(
                        attachment: current,
                        changeObserved: observedChange,
                        settled: true,
                        attempts: attempt + 1
                    )
                }
            } else {
                log(attempt: attempt, phase: "first_sample", difference: nil)
                latestCapture = current
            }

            if attempt < maxAttempts - 1 {
                try await Task.sleep(nanoseconds: sampleDelayNanoseconds)
            }
        }

        // The screen never stopped moving inside the window. Adopt the
        // freshest frame anyway; a mid-load shot at worst repeats guidance.
        log(attempt: maxAttempts, phase: "unsettled_adopt", difference: nil)
        if let latestCapture {
            succeeded = true
            return StableScreenCaptureResult(
                attachment: latestCapture,
                changeObserved: observedChange,
                settled: false,
                attempts: maxAttempts
            )
        }
        let final = try await captureService.captureMatchingScope(of: baseline)
        succeeded = true
        return StableScreenCaptureResult(
            attachment: final,
            changeObserved: observedChange,
            settled: false,
            attempts: maxAttempts + 1
        )
    }

    private static func log(attempt: Int, phase: String, difference: Double?) {
#if DEBUG
        if let difference {
            NSLog(
                "Vision stable capture attempt=%d phase=%@ diff=%.4f",
                attempt, phase, difference
            )
        } else {
            NSLog("Vision stable capture attempt=%d phase=%@", attempt, phase)
        }
#endif
    }

    /// `mean` is the whole-image average difference (used for stability);
    /// `blockMax` is the strongest per-block average difference (used for
    /// change detection, so small localized UI changes are not diluted).
    private static func differences(
        _ lhs: URL, _ rhs: URL
    ) async -> (mean: Double, blockMax: Double) {
        await Task.detached(priority: .utility) {
            guard let left = grayscalePixels(at: lhs),
                  let right = grayscalePixels(at: rhs),
                  left.count == right.count,
                  !left.isEmpty else { return (1, 1) }
            let side = comparisonSide
            let block = side / blockGrid
            var total = 0
            var blockMax = 0.0
            for blockY in 0..<blockGrid {
                for blockX in 0..<blockGrid {
                    var blockTotal = 0
                    for y in (blockY * block)..<((blockY + 1) * block) {
                        for x in (blockX * block)..<((blockX + 1) * block) {
                            let index = y * side + x
                            blockTotal += abs(Int(left[index]) - Int(right[index]))
                        }
                    }
                    total += blockTotal
                    blockMax = max(
                        blockMax,
                        Double(blockTotal) / Double(block * block * 255)
                    )
                }
            }
            return (
                Double(total) / Double(side * side * 255),
                blockMax
            )
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

/// A non-blocking confirmation shown only after Copilot has selected the
/// capture it will send to Vision. Stability probes stay invisible: flashing
/// every comparison frame would imply that each one was analyzed by the model.
@MainActor
final class CopilotCaptureCuePresenter {
    static let shared = CopilotCaptureCuePresenter()

    private var windows: [NSWindow] = []
    private var hideTask: Task<Void, Never>?
    private var generation = 0

    private init() {}

    func flash(for attachment: ScreenshotAttachment) {
        hideTask?.cancel()
        hide()
        generation += 1
        let currentGeneration = generation

        if let captureRect = attachment.captureRect, !captureRect.isEmpty {
            let window = makeWindow(frame: captureRect)
            windows = [window]
        } else {
            windows = NSScreen.screens.map { makeWindow(frame: $0.frame) }
        }

        let displayedWindows = windows
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: reduceMotion ? 140_000_000 : 70_000_000)
            guard !Task.isCancelled, self?.generation == currentGeneration else { return }

            if reduceMotion {
                self?.hide()
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                displayedWindows.forEach { $0.animator().alphaValue = 0 }
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard self?.generation == currentGeneration else { return }
                    self?.hide()
                }
            }
        }
    }

    private func makeWindow(frame: CGRect) -> NSWindow {
        let window = OverlayWindow(clickThrough: true)
        window.place(globalFrame: frame)
        window.alphaValue = 1
        window.contentView = CopilotCaptureCueView(
            frame: NSRect(origin: .zero, size: frame.size)
        )
        window.orderFrontRegardless()
        return window
    }

    private func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        hideTask = nil
    }
}

private final class CopilotCaptureCueView: NSView {
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

        NSColor.black.withAlphaComponent(0.22).setFill()
        bounds.fill()

        let borderRect = bounds.insetBy(dx: 8, dy: 8)
        let border = NSBezierPath(roundedRect: borderRect, xRadius: 12, yRadius: 12)
        border.lineWidth = 3
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        border.stroke()

        guard bounds.width >= 100, bounds.height >= 100,
              let eye = NSImage(
                systemSymbolName: "eye.fill",
                accessibilityDescription: "画面を確認しました"
              ) else { return }
        let symbol = eye.withSymbolConfiguration(
            .init(pointSize: 26, weight: .semibold)
        ) ?? eye
        symbol.isTemplate = true
        let symbolRect = NSRect(
            x: bounds.midX - 24,
            y: bounds.midY - 24,
            width: 48,
            height: 48
        )
        NSColor.white.withAlphaComponent(0.95).set()
        symbol.draw(in: symbolRect)
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
            let window = OverlayWindow(clickThrough: true)
            window.cover(screen)
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
