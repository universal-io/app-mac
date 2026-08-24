import CoreGraphics
import Foundation

/// The optional Selection Extension added to the existing Vision session.
///
/// `text` is the answer scope explicitly chosen by the user. Supporting
/// structure is intentionally stored beside it, never as a label or alias for
/// it, so a short AX/DOM label cannot replace a multi-node selection.
struct VisionSelectionContext: Equatable {
    private static let maxTextUTF16Units = 12_000
    private static let maxStructures = 64
    private static let maxFrames = 64

    /// One case on purpose. A Selection Extension exists only for text the user
    /// actually selected, so there is no kind for "something may be selected".
    enum Kind: String, Equatable {
        case text
    }

    enum AcquisitionCompleteness: String, Equatable {
        case complete
        case partial
    }

    enum Acquisition: String, Equatable {
        case axDocumentSelection = "ax_document_selection"
        case axSelectedText = "ax_selected_text"
        /// Swept on the pointing overlay: the range was resolved from the
        /// pointer through the accessibility text APIs while the application's
        /// own selection state stayed untouched. Its own value because calling
        /// it `ax_selected_text` would claim the application had a selection
        /// it never had.
        case axRangeAtPointer = "ax_range_at_pointer"
    }

    enum CaptureVisibility: String, Equatable {
        case visible
        case partial
        case offCapture = "off_capture"
        case unknown
    }

    let kind: Kind
    /// The answer scope the user chose. Non-optional because a Selection
    /// Extension without acquired text is not a selection at all.
    let text: String
    let structures: [VisionSelectionStructure]
    let frames: [CGRect]
    let acquisitionCompleteness: AcquisitionCompleteness
    let acquisition: Acquisition
    let captureVisibility: CaptureVisibility

    /// Encodes the optional Selection Extension without changing the base
    /// Vision request. Local text stays complete; only this wire value is
    /// bounded, preserving both ends of a long multi-node selection.
    func wirePayload(for attachment: ScreenshotAttachment) -> [String: Any]? {
        var payload: [String: Any] = [
            "kind": kind.rawValue,
            "acquisition_completeness": acquisitionCompleteness.rawValue,
            "acquisition": acquisition.rawValue,
            "capture_visibility": captureVisibility.rawValue,
        ]

        let normalizedText = VisionSelectionWireEncoding.normalized(text)
        let boundedText = normalizedText.map {
            VisionSelectionWireEncoding.boundedHeadTail(
                $0,
                maxUTF16Units: Self.maxTextUTF16Units
            )
        }
        if let value = boundedText?.value, !value.isEmpty {
            payload["text"] = value
        }
        payload["wire_truncated"] = boundedText?.truncated ?? false
        payload["original_utf16_units"] = normalizedText?.utf16.count ?? 0

        let wireFrames = Array(frames.prefix(Self.maxFrames)).compactMap {
            VisionSelectionWireEncoding.capturePixelFrame($0, for: attachment)
        }.map(VisionSelectionWireEncoding.framePayload)
        payload["frames"] = wireFrames

        let wireStructures = Array(structures.prefix(Self.maxStructures)).compactMap {
            $0.wirePayload(for: attachment)
        }
        payload["structures"] = wireStructures

        // Structures and frames cannot stand in for the selected text itself.
        guard payload["text"] != nil else { return nil }
        return payload
    }

    func resolvingCaptureVisibility(for attachment: ScreenshotAttachment) -> Self {
        guard !frames.isEmpty,
              let captureRect = attachment.captureRect,
              captureRect.width > 0,
              captureRect.height > 0 else {
            return self
        }
        var fullyVisible = 0
        var partiallyVisible = 0
        for frame in frames {
            let intersection = frame.intersection(captureRect)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                continue
            }
            if intersection == frame {
                fullyVisible += 1
            } else {
                partiallyVisible += 1
            }
        }
        let visibility: CaptureVisibility
        if fullyVisible == frames.count {
            visibility = .visible
        } else if fullyVisible > 0 || partiallyVisible > 0 {
            visibility = .partial
        } else {
            visibility = .offCapture
        }
        return Self(
            kind: kind,
            text: text,
            structures: structures,
            frames: frames,
            acquisitionCompleteness: acquisitionCompleteness,
            acquisition: acquisition,
            captureVisibility: visibility
        )
    }

    /// Selection frames clipped to the captured image and normalized to the
    /// capture's top-left 0...1 coordinate space. Each frame stays separate;
    /// nothing may replace multiple selected regions with one union box.
    func visibleNormalizedFrames(in attachment: ScreenshotAttachment) -> [CGRect] {
        guard let captureRect = attachment.captureRect,
              captureRect.width > 0,
              captureRect.height > 0 else {
            return []
        }
        return frames.compactMap { frame in
            let visible = frame.intersection(captureRect)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else {
                return nil
            }
            return CGRect(
                x: (visible.minX - captureRect.minX) / captureRect.width,
                y: (visible.minY - captureRect.minY) / captureRect.height,
                width: visible.width / captureRect.width,
                height: visible.height / captureRect.height
            )
        }
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

    fileprivate func wirePayload(for attachment: ScreenshotAttachment) -> [String: Any]? {
        var payload: [String: Any] = [
            "source": source.rawValue,
            "relationship": relationship.rawValue,
            "coverage": coverage.rawValue,
            "states": Array(states.prefix(16)).compactMap {
                VisionSelectionWireEncoding.boundedField($0, maxUTF16Units: 128)
            },
            "actions": Array(actions.prefix(16)).compactMap {
                VisionSelectionWireEncoding.boundedField($0, maxUTF16Units: 128)
            },
        ]
        if let role = VisionSelectionWireEncoding.boundedField(role, maxUTF16Units: 128) {
            payload["role"] = role
        }
        if let label = VisionSelectionWireEncoding.boundedField(label, maxUTF16Units: 512) {
            payload["label"] = label
        }
        if let parentLabel = VisionSelectionWireEncoding.boundedField(
            parentLabel,
            maxUTF16Units: 512
        ) {
            payload["parent_label"] = parentLabel
        }
        if let frame,
           let pixelFrame = VisionSelectionWireEncoding.capturePixelFrame(frame, for: attachment) {
            payload["frame"] = VisionSelectionWireEncoding.framePayload(pixelFrame)
        }
        guard payload["role"] != nil
                || payload["label"] != nil
                || payload["parent_label"] != nil
                || payload["frame"] != nil
                || !(payload["states"] as? [String] ?? []).isEmpty
                || !(payload["actions"] as? [String] ?? []).isEmpty else {
            return nil
        }
        return payload
    }
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
    static func resolve(candidates: [VisionSelectionCandidate]) -> VisionSelectionContext? {
        // Encountering a secure field anywhere on the acquisition path is a
        // hard stop. Do not salvage labels, frames, or text from another node.
        guard !candidates.contains(where: \.isSecure) else { return nil }

        let usable = candidates.compactMap { candidate -> TextCandidate? in
            guard let text = meaningfulText(candidate.directText) else { return nil }
            return TextCandidate(text: text, observation: candidate)
        }
        guard !usable.isEmpty else { return nil }

        let groups = Dictionary(grouping: usable, by: \.text).values
        guard let chosen = groups.max(by: { isLowerQuality($0, than: $1) }),
              let representative = chosen.max(by: { left, right in
                  if left.observation.scope.rawValue != right.observation.scope.rawValue {
                      return left.observation.scope.rawValue < right.observation.scope.rawValue
                  }
                  return left.observation.depth < right.observation.depth
              }) else { return nil }

        let structures = deduplicatedStructures(from: usable, chosenText: representative.text)
        let frames = deduplicatedFrames(usable.flatMap(\.observation.selectionFrames))
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
        from candidates: [TextCandidate],
        chosenText: String
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
                relationship: candidate.text == chosenText
                    ? .selectionContainer
                    : .intersectsSelection,
                states: [],
                actions: [],
                frame: valid(observation.containerFrame),
                // Coverage compares direct selected text only. Even `whole`
                // never means this container's label names the selection.
                coverage: candidate.text == chosenText ? .whole : .partial
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

private enum VisionSelectionWireEncoding {
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7f)
        }
        let normalized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func boundedField(_ value: String?, maxUTF16Units: Int) -> String? {
        guard let value = normalized(value) else { return nil }
        var result = ""
        var used = 0
        for character in value {
            let piece = String(character)
            guard used + piece.utf16.count <= maxUTF16Units else { break }
            result.append(character)
            used += piece.utf16.count
        }
        return result.isEmpty ? nil : result
    }

    static func boundedHeadTail(
        _ value: String,
        maxUTF16Units: Int
    ) -> (value: String, truncated: Bool) {
        let originalUnits = value.utf16.count
        guard originalUnits > maxUTF16Units else { return (value, false) }

        var omittedUnits = originalUnits
        var result = ""
        for _ in 0..<8 {
            let marker = "…[省略: \(omittedUnits) UTF-16 units]…"
            let contentBudget = max(0, maxUTF16Units - marker.utf16.count)
            let headBudget = contentBudget / 2
            let tailBudget = contentBudget - headBudget
            let head = prefix(value, maxUTF16Units: headBudget)
            let tail = suffix(value, maxUTF16Units: tailBudget)
            let newOmittedUnits = originalUnits - head.utf16.count - tail.utf16.count
            result = head + "…[省略: \(newOmittedUnits) UTF-16 units]…" + tail
            if newOmittedUnits == omittedUnits { break }
            omittedUnits = newOmittedUnits
        }
        return (result, true)
    }

    static func capturePixelFrame(
        _ frame: CGRect,
        for attachment: ScreenshotAttachment
    ) -> CGRect? {
        guard let captureRect = attachment.captureRect,
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

    static func framePayload(_ frame: CGRect) -> [String: Double] {
        [
            "x": Double(frame.minX),
            "y": Double(frame.minY),
            "width": Double(frame.width),
            "height": Double(frame.height),
        ]
    }

    private static func prefix(_ value: String, maxUTF16Units: Int) -> String {
        var result = ""
        var used = 0
        for character in value {
            let piece = String(character)
            guard used + piece.utf16.count <= maxUTF16Units else { break }
            result.append(character)
            used += piece.utf16.count
        }
        return result
    }

    private static func suffix(_ value: String, maxUTF16Units: Int) -> String {
        var pieces: [String] = []
        var used = 0
        for character in value.reversed() {
            let piece = String(character)
            guard used + piece.utf16.count <= maxUTF16Units else { break }
            pieces.append(piece)
            used += piece.utf16.count
        }
        return pieces.reversed().joined()
    }
}
