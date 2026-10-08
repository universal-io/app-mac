import CoreImage
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// What the voice layer sees (master plan R18 決定4): the working display, at
/// most one frame a second, and only when it changed. The POC's numbers —
/// long edge 1536, JPEG 0.8, signature threshold 0.01 — kept until measured
/// otherwise, so the two experiments stay comparable.
///
/// The cursor is in the picture on purpose: the persona reads 「これ」「ここ」
/// as where the pointer is. This app's own windows are not.
final class CompanionScreenFeed: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let longEdge = 1_536
    static let jpegQuality = 0.8

    /// A changed frame as JPEG. Called on the feed's queue.
    var onFrame: ((Data) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.universal-io.companion.screen")
    private let imageContext = CIContext()
    /// Touched only on `queue`.
    private var lastSentSignature: [UInt8]?

    func start(displayID: CGDirectDisplayID?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
        else { throw ScreenshotCaptureError.noCaptureTarget }
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter { $0.processID == ownProcessID },
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        let scale = Double(Self.longEdge) / Double(max(display.width, display.height))
        configuration.width = Int((Double(display.width) * scale).rounded())
        configuration.height = Int((Double(display.height) * scale).rounded())
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // Screen Capture Kit also delivers "nothing changed" frames; only a
        // complete one carries a picture.
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let frame = imageContext.createCGImage(image, from: image.extent),
              let signature = ScreenSignature.of(frame)
        else { return }
        if let last = lastSentSignature,
           ScreenSignature.difference(last, signature) < ScreenSignature.sendThreshold {
            return
        }
        guard let jpeg = Self.jpeg(frame) else { return }
        lastSentSignature = signature
        onFrame?(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Diagnostics.record("companion.screenStopped", details: [
            ("error", .code(DiagnosticErrorClass(error))),
        ])
    }

    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
