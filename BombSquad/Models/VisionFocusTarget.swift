import CoreGraphics
import Foundation

/// The optional subject of a Vision session. Coordinates stay in global AX
/// space locally so A3 can draw the overlay; only the Gateway payload converts
/// them into capture-local pixels. No AX element reference is retained.
struct VisionFocusTarget: Equatable {
    enum Kind: String {
        case selectedText = "selected_text"
        case accessibilityElement = "accessibility_element"
        case region
    }

    enum Source: String {
        case axSelectedText = "ax_selected_text"
        case axElement = "ax_element"
        case userRegion = "user_region"
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
        case .region:
            return "選択した領域"
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
        case .userRegion:
            return "選択領域"
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

    static func region(_ frame: CGRect) -> VisionFocusTarget? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        return VisionFocusTarget(
            kind: .region,
            text: nil,
            role: nil,
            label: nil,
            frame: frame,
            source: .userRegion
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
        case .region:
            guard payload["frame"] != nil else { return nil }
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
             (.accessibilityElement, .axElement),
             (.region, .userRegion):
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
