import CoreGraphics
import Foundation

/// The optional subject of a Vision session. Coordinates stay in global AX
/// space locally so A3 can draw the overlay; only the Gateway payload converts
/// them into capture-local pixels. No AX element reference is retained.
struct VisionFocusTarget: Equatable {
    enum Kind: String {
        case selectedText = "selected_text"
        case accessibilityElement = "accessibility_element"
    }

    enum Source: String {
        case axSelectedText = "ax_selected_text"
        case axElement = "ax_element"
    }

    private static let maxTextCharacters = 12_000
    private static let maxRoleCharacters = 128
    private static let maxLabelCharacters = 512

    let kind: Kind
    let text: String?
    let role: String?
    let label: String?
    let frame: CGRect?
    let source: Source

    var displayTitle: String {
        switch kind {
        case .selectedText:
            return "選択中のテキスト"
        case .accessibilityElement:
            switch role {
            case "AXButton":
                return "選択中のボタン"
            case "AXLink":
                return "選択中のリンク"
            case "AXImage":
                return "選択中の画像"
            case "AXCheckBox":
                return "選択中のチェックボックス"
            case "AXRadioButton":
                return "選択中のラジオボタン"
            case "AXTab":
                return "選択中のタブ"
            case "AXRow":
                return "選択中の行"
            case "AXCell":
                return "選択中のセル"
            case "AXTextField", "AXTextArea":
                return "選択中のテキストフィールド"
            default:
                return "選択中の画面要素"
            }
        }
    }

    var sourceDescription: String {
        switch source {
        case .axSelectedText:
            return "選択テキスト"
        case .axElement:
            return "画面要素"
        }
    }

    static func from(snapshot: AXFocusSnapshot) -> VisionFocusTarget? {
        guard !snapshot.isSecureField else { return nil }
        if let text = normalized(snapshot.selectedText), !text.isEmpty {
            return VisionFocusTarget(
                kind: .selectedText,
                text: text,
                role: snapshot.role,
                label: snapshot.label,
                frame: snapshot.frame,
                source: .axSelectedText
            )
        }
        guard AXFocusLaunchDecision.destination(for: snapshot) == .focusedVision else {
            return nil
        }
        return VisionFocusTarget(
            kind: .accessibilityElement,
            text: nil,
            role: snapshot.role,
            label: snapshot.label,
            frame: snapshot.frame,
            source: .axElement
        )
    }

    /// Returns the strict wire representation. Text is bounded here so the
    /// session can keep the complete local selection for the A3 target card.
    func wirePayload(for attachment: ScreenshotAttachment) -> [String: Any]? {
        guard sourceMatchesKind else { return nil }

        var payload: [String: Any] = [
            "kind": kind.rawValue,
            "source": source.rawValue,
        ]
        let normalizedText = Self.normalized(text)
        let boundedText = normalizedText.map {
            Self.bounded($0, maxUTF16Units: Self.maxTextCharacters)
        }
        let truncatedText = boundedText?.value
        let truncated = boundedText?.truncated ?? false
        if let truncatedText, !truncatedText.isEmpty {
            payload["text"] = truncatedText
        }
        if let role = Self.normalized(role), !role.isEmpty {
            payload["role"] = Self.bounded(
                role,
                maxUTF16Units: Self.maxRoleCharacters
            ).value
        }
        if let label = Self.normalized(label), !label.isEmpty {
            payload["label"] = Self.bounded(
                label,
                maxUTF16Units: Self.maxLabelCharacters
            ).value
        }
        if let frame = capturePixelFrame(for: attachment) {
            payload["frame"] = [
                "x": Double(frame.minX),
                "y": Double(frame.minY),
                "width": Double(frame.width),
                "height": Double(frame.height),
            ]
        }
        payload["truncated"] = truncated

        switch kind {
        case .selectedText:
            guard payload["text"] != nil else { return nil }
        case .accessibilityElement:
            guard payload["role"] != nil || payload["label"] != nil || payload["frame"] != nil else {
                return nil
            }
        }
        return payload
    }

    /// Returns the target in the preview's normalized top-left coordinate
    /// space. A target outside the captured display, or a capture whose
    /// origin is unknown, deliberately has no drawable location.
    func normalizedFrame(in attachment: ScreenshotAttachment) -> CGRect? {
        guard let pixelFrame = capturePixelFrame(for: attachment),
              let pixelWidth = attachment.pixelWidth,
              let pixelHeight = attachment.pixelHeight,
              pixelWidth > 0,
              pixelHeight > 0 else {
            return nil
        }
        return CGRect(
            x: pixelFrame.minX / CGFloat(pixelWidth),
            y: pixelFrame.minY / CGFloat(pixelHeight),
            width: pixelFrame.width / CGFloat(pixelWidth),
            height: pixelFrame.height / CGFloat(pixelHeight)
        )
    }

    private var sourceMatchesKind: Bool {
        switch (kind, source) {
        case (.selectedText, .axSelectedText),
             (.accessibilityElement, .axElement):
            return true
        default:
            return false
        }
    }

    private func capturePixelFrame(for attachment: ScreenshotAttachment) -> CGRect? {
        guard let frame,
              let captureRect = attachment.captureRect,
              let pixelWidth = attachment.pixelWidth,
              let pixelHeight = attachment.pixelHeight,
              captureRect.width > 0,
              captureRect.height > 0,
              pixelWidth > 0,
              pixelHeight > 0 else {
            return nil
        }
        let visible = frame.intersection(captureRect)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        let scaleX = CGFloat(pixelWidth) / captureRect.width
        let scaleY = CGFloat(pixelHeight) / captureRect.height
        return CGRect(
            x: (visible.minX - captureRect.minX) * scaleX,
            y: (visible.minY - captureRect.minY) * scaleY,
            width: visible.width * scaleX,
            height: visible.height * scaleY
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7f)
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// JavaScript validates String.length (UTF-16 code units), so bound by the
    /// same unit here. Swift Character counts would let emoji exceed the
    /// Gateway limit even though the visible character count looked valid.
    private static func bounded(
        _ value: String,
        maxUTF16Units: Int
    ) -> (value: String, truncated: Bool) {
        var result = ""
        var used = 0
        for character in value {
            let piece = String(character)
            let units = piece.utf16.count
            guard used + units <= maxUTF16Units else { break }
            result.append(character)
            used += units
        }
        return (result, used < value.utf16.count)
    }
}

/// The next-generation optional input to the existing Vision session.
///
/// `text` is the answer scope explicitly chosen by the user. Supporting
/// structure is intentionally stored beside it, never as a label or alias for
/// it, so a short AX/DOM label cannot replace a multi-node selection.
struct VisionSelectionContext: Equatable {
    enum Kind: String, Equatable {
        case text
        case accessibilityElement = "accessibility_element"
        case visualOnly = "visual_only"
    }

    enum AcquisitionCompleteness: String, Equatable {
        case complete
        case partial
        case visualOnly = "visual_only"
    }

    enum Acquisition: String, Equatable {
        case axDocumentSelection = "ax_document_selection"
        case axSelectedText = "ax_selected_text"
        case axElement = "ax_element"
        case visualHighlight = "visual_highlight"
    }

    enum CaptureVisibility: String, Equatable {
        case visible
        case partial
        case offCapture = "off_capture"
        case unknown
    }

    let kind: Kind
    let text: String?
    let structures: [VisionSelectionStructure]
    let frames: [CGRect]
    let acquisitionCompleteness: AcquisitionCompleteness
    let acquisition: Acquisition
    let captureVisibility: CaptureVisibility

    static func visualOnly() -> Self {
        Self(
            kind: .visualOnly,
            text: nil,
            structures: [],
            frames: [],
            acquisitionCompleteness: .visualOnly,
            acquisition: .visualHighlight,
            captureVisibility: .unknown
        )
    }
}

struct VisionSelectionStructure: Equatable {
    enum Source: String, Equatable {
        case ax
        case dom
    }

    enum Relationship: String, Equatable {
        case selectionContainer = "selection_container"
        case intersectsSelection = "intersects_selection"
        case surroundingContext = "surrounding_context"
    }

    enum Coverage: String, Equatable {
        case whole
        case partial
        case context
        case unknown
    }

    let source: Source
    let role: String?
    let label: String?
    let parentLabel: String?
    let relationship: Relationship
    let states: [String]
    let actions: [String]
    let frame: CGRect?
    let coverage: Coverage
}

/// A value-only observation from one AX container. Element references never
/// enter this resolver. `rangeEvidence` can strengthen diagnostics and frame
/// collection but cannot replace or veto stable direct selected text.
struct VisionSelectionCandidate: Equatable {
    enum Scope: Int, Equatable {
        case focusedElement
        case ancestor
        case document
    }

    enum RangeEvidence: Equatable {
        case unavailable
        case matching
        case mismatching
    }

    let directText: String?
    let role: String?
    let label: String?
    let containerFrame: CGRect?
    let selectionFrames: [CGRect]
    let scope: Scope
    let depth: Int
    let pass: Int
    let rangeEvidence: RangeEvidence
    let isSecure: Bool
}

/// Chooses the selected text, not the most prominent structure around it.
/// Document-level direct text wins when available; native/editable controls
/// fall back to agreement across the observed containers and passes.
enum VisionSelectionResolver {
    static func resolve(
        candidates: [VisionSelectionCandidate],
        visualSelectionHint: Bool = false
    ) -> VisionSelectionContext? {
        // Encountering a secure field anywhere on the acquisition path is a
        // hard stop. Do not salvage labels, frames, or text from another node.
        guard !candidates.contains(where: \.isSecure) else { return nil }

        let usable = candidates.compactMap { candidate -> TextCandidate? in
            guard let text = meaningfulText(candidate.directText) else { return nil }
            return TextCandidate(text: text, observation: candidate)
        }
        guard !usable.isEmpty else {
            return visualSelectionHint ? .visualOnly() : nil
        }

        let groups = Dictionary(grouping: usable, by: \.text).values
        guard let chosen = groups.max(by: { isLowerQuality($0, than: $1) }),
              let representative = chosen.max(by: { left, right in
                  if left.observation.scope.rawValue != right.observation.scope.rawValue {
                      return left.observation.scope.rawValue < right.observation.scope.rawValue
                  }
                  return left.observation.depth < right.observation.depth
              }) else {
            return visualSelectionHint ? .visualOnly() : nil
        }

        let structures = deduplicatedStructures(from: chosen)
        let frames = deduplicatedFrames(chosen.flatMap(\.observation.selectionFrames))
        let hasDocument = chosen.contains { $0.observation.scope == .document }
        return VisionSelectionContext(
            kind: .text,
            text: representative.text,
            structures: structures,
            frames: frames,
            acquisitionCompleteness: .complete,
            acquisition: hasDocument ? .axDocumentSelection : .axSelectedText,
            captureVisibility: .unknown
        )
    }

    private struct TextCandidate {
        let text: String
        let observation: VisionSelectionCandidate
    }

    private static func meaningfulText(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func isLowerQuality(
        _ left: [TextCandidate],
        than right: [TextCandidate]
    ) -> Bool {
        let leftScore = score(left)
        let rightScore = score(right)
        if leftScore.hasDocument != rightScore.hasDocument {
            return !leftScore.hasDocument
        }
        if leftScore.passCount != rightScore.passCount {
            return leftScore.passCount < rightScore.passCount
        }
        if leftScore.observationCount != rightScore.observationCount {
            return leftScore.observationCount < rightScore.observationCount
        }
        if leftScore.utf16Units != rightScore.utf16Units {
            return leftScore.utf16Units < rightScore.utf16Units
        }
        return leftScore.maxDepth < rightScore.maxDepth
    }

    private static func score(_ group: [TextCandidate]) -> (
        hasDocument: Bool,
        passCount: Int,
        observationCount: Int,
        utf16Units: Int,
        maxDepth: Int
    ) {
        (
            hasDocument: group.contains { $0.observation.scope == .document },
            passCount: Set(group.map(\.observation.pass)).count,
            observationCount: group.count,
            utf16Units: group.first?.text.utf16.count ?? 0,
            maxDepth: group.map(\.observation.depth).max() ?? 0
        )
    }

    private static func deduplicatedStructures(
        from candidates: [TextCandidate]
    ) -> [VisionSelectionStructure] {
        var result: [VisionSelectionStructure] = []
        for candidate in candidates {
            let observation = candidate.observation
            guard observation.role != nil
                    || observation.label != nil
                    || valid(observation.containerFrame) != nil else {
                continue
            }
            let structure = VisionSelectionStructure(
                source: .ax,
                role: observation.role,
                label: observation.label,
                parentLabel: nil,
                relationship: .selectionContainer,
                states: [],
                actions: [],
                frame: valid(observation.containerFrame),
                // This describes text coverage by the container, not whether
                // its label semantically names the selected text.
                coverage: .whole
            )
            if !result.contains(structure) {
                result.append(structure)
            }
        }
        return result
    }

    private static func deduplicatedFrames(_ frames: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for frame in frames {
            guard let frame = valid(frame), !result.contains(frame) else { continue }
            result.append(frame)
        }
        return result
    }

    private static func valid(_ frame: CGRect?) -> CGRect? {
        guard let frame,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return nil
        }
        return frame
    }
}
