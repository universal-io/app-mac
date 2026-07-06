import AppKit
import SwiftUI

/// A rectangle the user drew on the screenshot preview to point at a region
/// ("about this part…"). Coordinates are normalized to the image (0-1,
/// top-left origin) so they survive zooming, panning, and downscaling.
struct ScreenshotAnnotation: Identifiable, Equatable {
    enum Tint: String, CaseIterable, Identifiable {
        case red
        case blue

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .red: return .red
            case .blue: return .blue
            }
        }

        var nsColor: NSColor {
            switch self {
            case .red: return .systemRed
            case .blue: return .systemBlue
            }
        }
    }

    let id = UUID()
    /// Normalized image coordinates (0-1, top-left origin).
    var rect: CGRect
    var tint: Tint
}

/// What a mouse drag does on the screenshot preview.
enum ScreenshotPreviewTool {
    /// Drag moves the zoomed image around (Illustrator's hand tool).
    case pan
    /// Drag draws an annotation rectangle.
    case annotate
}

/// Parses the navigator's location marker: the model appends
/// `[[loc:x0,y0,x1,y1]]` (integers on a 0-1000 grid over the latest
/// screenshot) to an answer only when it is confident about the position.
/// The verbal description is the contract; the box is a bonus — so parsing
/// failures simply mean "no highlight", never an error.
enum NavigatorLocator {
    private static let marker = try! NSRegularExpression(
        pattern: #"\[\[loc:(\d{1,4}),(\d{1,4}),(\d{1,4}),(\d{1,4})\]\]"#
    )
    /// The exact on-screen label of the target element. When local OCR finds
    /// this string, its measured rectangle beats the model's estimated box —
    /// "what" from the VLM, "where" from the device (pixel-accurate).
    private static let targetMarker = try! NSRegularExpression(
        pattern: #"\[\[target:([^\]]{1,120})\]\]"#
    )
    /// A marker still being streamed at the end of the text.
    private static let partialMarker = try! NSRegularExpression(
        pattern: #"\[?\[(?:loc|target):[^\]]*\]?$"#
    )

    /// Splits an answer into display text (markers removed), the model's own
    /// highlight box (normalized image coordinates), and the target label.
    static func extract(from text: String) -> (text: String, box: CGRect?, target: String?) {
        var box: CGRect?
        let range = NSRange(text.startIndex..., in: text)
        if let match = marker.firstMatch(in: text, range: range) {
            func value(_ index: Int) -> Double {
                guard let r = Range(match.range(at: index), in: text) else { return 0 }
                return min(Double(text[r]) ?? 0, 1000) / 1000
            }
            let (x0, y0, x1, y1) = (value(1), value(2), value(3), value(4))
            let rect = CGRect(
                x: min(x0, x1),
                y: min(y0, y1),
                width: abs(x1 - x0),
                height: abs(y1 - y0)
            )
            // Degenerate or full-image boxes carry no information.
            if rect.width > 0.005, rect.height > 0.005, rect.width < 0.98 || rect.height < 0.98 {
                box = rect
            }
        }

        var target: String?
        if let match = targetMarker.firstMatch(in: text, range: range),
           let r = Range(match.range(at: 1), in: text) {
            let label = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { target = label }
        }

        return (strippingMarkers(text), box, target)
    }

    /// Removes complete markers anywhere and a partially streamed marker at
    /// the end, so tokens of `[[loc:…` never flash up during streaming.
    static func strippingMarkers(_ text: String) -> String {
        var result = text
        for expression in [marker, targetMarker, partialMarker] {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result, range: range, withTemplate: ""
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
