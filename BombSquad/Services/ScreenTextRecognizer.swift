import Foundation
import Vision

/// On-device OCR for navigator screenshots (docs/navigator-copilot-plan.md §9-c).
/// Extracting the screen text locally lets the client ship a much smaller
/// image (faster upload, cheaper inference) while the model still reads exact
/// strings — and keeps raw pixels on the device wherever text suffices.
/// One recognized text fragment with its position in the image
/// (normalized 0-1, TOP-left origin — the navigator's shared convention).
struct RecognizedTextFragment {
    let text: String
    let rect: CGRect
}

/// OCR result: the joined text goes over the wire; the fragments stay on
/// the device and give exact rectangles for AI-named targets ("what" from
/// the VLM, "where" from local OCR — pixel-accurate when the text matches).
struct RecognizedScreenText {
    let joinedText: String
    let fragments: [RecognizedTextFragment]
}

enum ScreenTextRecognizer {
    /// Character budget matching the gateway's ocr_text limit.
    private static let maxCharacters = 16_000

    /// Recognizes text in reading order (top-to-bottom, left-to-right within
    /// a line band). Returns nil when nothing was recognized or on failure —
    /// OCR is an accelerator, never a blocker.
    static func recognize(at url: URL) async -> RecognizedScreenText? {
        await Task.detached(priority: .userInitiated) {
            recognizeSync(at: url)
        }.value
    }

    private static func recognizeSync(at url: URL) -> RecognizedScreenText? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("[ScreenTextRecognizer] OCR failed: %@", error.localizedDescription)
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return nil }

        // Vision returns observations in an unspecified order; sort into rough
        // reading order. Y is bottom-origin, so higher minY means higher on
        // screen. Group into horizontal bands to keep same-line fragments
        // together.
        let candidates: [RecognizedTextFragment] = observations.compactMap {
            guard let top = $0.topCandidates(1).first else { return nil }
            // Vision's boundingBox is bottom-left normalized; flip to the
            // navigator's top-left convention.
            let box = $0.boundingBox
            let rect = CGRect(
                x: box.minX,
                y: 1 - box.maxY,
                width: box.width,
                height: box.height
            )
            return RecognizedTextFragment(text: top.string, rect: rect)
        }
        let bandHeight: CGFloat = 0.012
        let sorted = candidates.sorted { lhs, rhs in
            let lhsBand = Int(lhs.rect.minY / bandHeight)
            let rhsBand = Int(rhs.rect.minY / bandHeight)
            if lhsBand != rhsBand { return lhsBand < rhsBand }
            return lhs.rect.minX < rhs.rect.minX
        }

        var joined = sorted.map(\.text).joined(separator: "\n")
        if joined.count > maxCharacters {
            joined = String(joined.prefix(maxCharacters))
        }
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RecognizedScreenText(joinedText: trimmed, fragments: sorted)
    }
}
