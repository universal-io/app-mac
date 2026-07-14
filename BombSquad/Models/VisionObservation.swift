import CoreGraphics
import Foundation

/// Versioned snapshot of one captured screen state. This is the Vision
/// projection of the shared Context architecture: immutable per capture,
/// privacy-bounded, and suitable for replay/eval. It intentionally carries no
/// tenant or user identity; the Gateway resolves those from authentication.
struct VisionObservation {
    struct Candidate {
        let id: String
        let source: String
        let role: String?
        let label: String
        let rect: CGRect?
        let parentLabel: String?
        let states: [String]

        var wirePayload: [String: Any] {
            var payload: [String: Any] = [
                "id": id,
                "source": source,
                "label": label,
                "states": states,
            ]
            if let role { payload["role"] = role }
            if let parentLabel { payload["parent_label"] = parentLabel }
            if let rect {
                payload["rect"] = [
                    "x": Double(rect.minX),
                    "y": Double(rect.minY),
                    "width": Double(rect.width),
                    "height": Double(rect.height),
                ]
            }
            return payload
        }
    }

    let captureID: UUID
    let capturedAt: Date
    let captureScope: ScreenshotCaptureScope
    let pixelWidth: Int?
    let pixelHeight: Int?
    let screenRect: CGRect?
    let environment: AppEnvironmentSnapshot?
    let transitionState: String
    let candidates: [Candidate]

    static func make(
        attachment: ScreenshotAttachment,
        environment: AppEnvironmentSnapshot?,
        ocr: RecognizedScreenText?,
        axCandidates: [Candidate] = []
    ) -> VisionObservation {
        let boundedAX = Array(axCandidates.prefix(500))
        let remaining = max(0, 500 - boundedAX.count)
        let fragments = ocr.map { Array($0.fragments.prefix(remaining)) } ?? []
        let ocrCandidates = fragments.enumerated().map { index, fragment in
            Candidate(
                id: "ocr:\(index)",
                source: "ocr",
                role: "text",
                label: String(fragment.text.prefix(512)),
                rect: normalized(fragment.rect),
                parentLabel: nil,
                states: []
            )
        }
        return VisionObservation(
            captureID: attachment.id,
            capturedAt: attachment.createdAt,
            captureScope: attachment.captureScope,
            pixelWidth: attachment.pixelWidth,
            pixelHeight: attachment.pixelHeight,
            screenRect: attachment.captureRect,
            environment: environment,
            transitionState: "stable",
            candidates: boundedAX + ocrCandidates
        )
    }

    func wirePayload(includeEnvironment: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "schema_version": 1,
            "capture_id": captureID.uuidString.lowercased(),
            "captured_at": Self.iso8601(capturedAt),
            "capture_scope": captureScope.rawValue,
            "coordinate_space": "normalized_top_left",
            "transition_state": transitionState,
            "candidates": candidates.map(\.wirePayload),
        ]
        if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
            payload["pixel_size"] = ["width": pixelWidth, "height": pixelHeight]
        }
        if let screenRect, screenRect.width > 0, screenRect.height > 0 {
            payload["screen_rect"] = [
                "x": Double(screenRect.minX),
                "y": Double(screenRect.minY),
                "width": Double(screenRect.width),
                "height": Double(screenRect.height),
            ]
        }
        if includeEnvironment, let environment {
            payload["environment"] = environment.wirePayload
        }
        return payload
    }

    private static func normalized(_ rect: CGRect) -> CGRect {
        let x = min(max(rect.minX, 0), 1)
        let y = min(max(rect.minY, 0), 1)
        let width = min(max(rect.width, 0.000_001), 1 - x)
        let height = min(max(rect.height, 0.000_001), 1 - y)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Capture-time app/window identity shared by future Compose and Vision
/// projections. URL is reserved until browser-specific AX extraction lands.
struct AppEnvironmentSnapshot {
    let appName: String
    let bundleID: String?
    let windowTitle: String?
    let url: String?

    var wirePayload: [String: Any] {
        var payload: [String: Any] = ["app_name": String(appName.prefix(256))]
        if let bundleID, !bundleID.isEmpty {
            payload["bundle_id"] = String(bundleID.prefix(256))
        }
        if let windowTitle, !windowTitle.isEmpty {
            payload["window_title"] = String(windowTitle.prefix(1_024))
        }
        if let url, !url.isEmpty {
            payload["url"] = String(url.prefix(4_096))
        }
        return payload
    }
}
