import Foundation

/// One action the model proposes after reading the screen. The current
/// user-facing vision flow is still "summary -> follow-up question ->
/// optional navigator hand-off"; draft-carrying actions are a forward-looking
/// hook for reply/fill assistance that exists in code before that UX is fully
/// adopted in the panel.
struct VisionSuggestedAction: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case reply
        case fillForm = "fill_form"
        case task
        case infoOnly = "info_only"

        var label: String {
            switch self {
            case .reply: return "返信"
            case .fillForm: return "入力"
            case .task: return "タスク"
            case .infoOnly: return "情報"
            }
        }
    }

    var id = UUID()
    let title: String
    let kind: Kind
    /// Deployable text for `reply` (and prefill guidance for `fill_form`).
    /// Today this mostly acts as latent capability; the mainstream screenshot
    /// flow does not yet revolve around returning this text into another form.
    let draft: String

    private enum CodingKeys: String, CodingKey {
        case title, kind, draft
    }

    var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// "See → understand → respond": what is happening on screen, what it says,
/// what is being asked of the user, and prepared actions to approve.
struct VisionInterpretationResult: Codable, Hashable {
    var modelID: String?
    /// 1-2 sentence summary of what is happening on this screen.
    let situation: String
    /// Body text read off the screen, as structured Markdown.
    let extracted: String
    /// What the user is being asked to do (requests, deadlines, facts).
    let asks: [String]
    let suggestedActions: [VisionSuggestedAction]

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case situation
        case extracted
        case asks
        case suggestedActions = "suggested_actions"
    }

    var copyText: String {
        var parts: [String] = []
        if !situation.isEmpty {
            parts.append("状況:\n\(situation)")
        }
        if !extracted.isEmpty {
            parts.append("読み取った内容:\n\(extracted)")
        }
        if !asks.isEmpty {
            parts.append("求められていること:\n" + asks.map { "- \($0)" }.joined(separator: "\n"))
        }
        for action in suggestedActions where action.hasDraft {
            parts.append("\(action.title):\n\(action.draft)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Tolerant decoding: models occasionally rename keys or return the
    /// legacy shape (summary / visible_text / interpretation), especially on
    /// the fallback model. Map whatever arrived onto the current schema.
    static func decodeFlexible(from data: Data) throws -> VisionInterpretationResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("vision result is not a JSON object")
        }

        let situation = stringValue(object, keys: ["situation", "summary", "状況", "要約"]) ?? ""
        var extracted = stringValue(object, keys: ["extracted", "interpretation", "explanation", "説明"]) ?? ""
        if extracted.isEmpty {
            extracted = stringListValue(object, keys: ["visible_text", "visibleText", "text", "ocr_text"])
                .map { "- \($0)" }
                .joined(separator: "\n")
        }

        return VisionInterpretationResult(
            modelID: stringValue(object, keys: ["model_id", "modelID"]),
            situation: situation,
            extracted: extracted,
            asks: stringListValue(object, keys: ["asks", "求められていること"]),
            suggestedActions: actionsValue(object)
        )
    }

    private static func actionsValue(_ object: [String: Any]) -> [VisionSuggestedAction] {
        guard let raw = object["suggested_actions"] ?? object["suggestedActions"] ?? object["actions"] else {
            return []
        }

        if let items = raw as? [[String: Any]] {
            return items.compactMap { item in
                guard let title = stringValue(item, keys: ["title", "name"]), !title.isEmpty else { return nil }
                let kindRaw = stringValue(item, keys: ["kind", "type"]) ?? ""
                return VisionSuggestedAction(
                    title: title,
                    kind: VisionSuggestedAction.Kind(rawValue: kindRaw) ?? .infoOnly,
                    draft: stringValue(item, keys: ["draft", "text", "body"]) ?? ""
                )
            }
        }

        // Legacy shape: a flat list of action descriptions.
        if let strings = raw as? [String] {
            return strings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { VisionSuggestedAction(title: $0, kind: .infoOnly, draft: "") }
        }
        return []
    }

    private static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let value = object[key] {
                return describe(value)
            }
        }
        return nil
    }

    private static func stringListValue(_ object: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            guard let value = object[key] else { continue }
            if let array = value as? [String] {
                return array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            if let array = value as? [Any] {
                return array.compactMap { describe($0) }.filter { !$0.isEmpty }
            }
            if let string = value as? String {
                return splitLines(string)
            }
            if let described = describe(value), !described.isEmpty {
                return [described]
            }
        }
        return []
    }

    private static func splitLines(_ string: String) -> [String] {
        string
            .components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•"))
            }
            .filter { !$0.isEmpty }
    }

    private static func describe(_ value: Any) -> String? {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return nil
    }
}
