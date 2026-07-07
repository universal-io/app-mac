import Foundation

/// An API backend. OpenAI and Groq share the OpenAI-compatible Chat Completions
/// surface; Anthropic has its own Messages API.
enum APIVendor: String {
    case openAI
    case anthropic
    case groq

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Claude"
        case .groq: return "Groq"
        }
    }

    /// Keychain account under which this vendor's API key is stored.
    var keychainAccount: String {
        switch self {
        case .openAI: return "openai-api-key"
        case .anthropic: return "anthropic-api-key"
        case .groq: return "groq-api-key"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openAI: return "OpenAI API キー (sk-...)"
        case .anthropic: return "Claude API キー (sk-ant-...)"
        case .groq: return "Groq API キー (gsk_...)"
        }
    }

    /// Chat Completions endpoint for OpenAI-compatible vendors; nil for Anthropic.
    var openAICompatibleEndpoint: URL? {
        switch self {
        case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")
        case .groq: return URL(string: "https://api.groq.com/openai/v1/chat/completions")
        case .anthropic: return nil
        }
    }
}

/// A selectable review model. The catalog is the single source of truth for the
/// model picker; adding a model is one entry here.
struct ReviewModel: Identifiable, Hashable {
    let id: String              // stable id for persistence
    let displayName: String
    let vendor: APIVendor
    let apiModelID: String      // exact id sent to the API
    let hint: String
    let reasoningEffort: String? // gpt-oss reasoning models only

    static let catalog: [ReviewModel] = [
        ReviewModel(id: "groq-gpt-oss-120b",
                    displayName: "Groq · gpt-oss-120b（推奨・高速高品質）",
                    vendor: .groq, apiModelID: "openai/gpt-oss-120b",
                    hint: "高速のままトーン判定を強化。トゲ取り重視の既定。reasoning_effort=medium。",
                    reasoningEffort: "medium"),
        ReviewModel(id: "groq-gpt-oss-20b",
                    displayName: "Groq · gpt-oss-20b（最速）",
                    vendor: .groq, apiModelID: "openai/gpt-oss-20b",
                    hint: "最速・最安。摩擦を限界まで下げたい時。reasoning_effort=low。",
                    reasoningEffort: "low"),
        ReviewModel(id: "openai-gpt-4.1-nano",
                    displayName: "OpenAI · gpt-4.1-nano（高速）",
                    vendor: .openAI, apiModelID: "gpt-4.1-nano",
                    hint: "OpenAI の最速・最安クラス。非推論で安定。",
                    reasoningEffort: nil),
        ReviewModel(id: "openai-gpt-4.1-mini",
                    displayName: "OpenAI · gpt-4.1-mini（バランス）",
                    vendor: .openAI, apiModelID: "gpt-4.1-mini",
                    hint: "速度と品質のバランス。",
                    reasoningEffort: nil),
        ReviewModel(id: "anthropic-claude-sonnet-4-6",
                    displayName: "Claude · Sonnet 4.6（品質）",
                    vendor: .anthropic, apiModelID: "claude-sonnet-4-6",
                    hint: "トーンのニュアンス重視。",
                    reasoningEffort: nil),
        ReviewModel(id: "anthropic-claude-opus-4-8",
                    displayName: "Claude · Opus 4.8（最高品質）",
                    vendor: .anthropic, apiModelID: "claude-opus-4-8",
                    hint: "最も丁寧。重要なメッセージ向け（低速）。",
                    reasoningEffort: nil),
    ]

    /// Fastest model; the default selection.
    static let defaultModel = catalog[0]

    static func find(id: String?) -> ReviewModel {
        catalog.first { $0.id == id } ?? defaultModel
    }
}

/// Lightweight app-wide settings backed by UserDefaults.
enum AppSettings {
    static let selectedModelKey = "selectedModelID"
    static let selectedVisionModelKey = "selectedVisionModelID"
    static let isHistoryEnabledKey = "isHistoryEnabled"
    static let isContextCaptureEnabledKey = "isContextCaptureEnabled"
    static let isMemoryEnabledKey = "isMemoryEnabled"
    static let isNavigatorEnabledKey = "isNavigatorEnabled"
    static let isNavigatorAutoFirstTurnEnabledKey = "isNavigatorAutoFirstTurnEnabled"
    static let outputLanguageKey = "outputLanguage"
    static let localHistoryLimit = 100
    static let defaultVisionModelID = "gpt-5.4-mini"

    /// Persisted default for the deliverable language. Lives in settings (not
    /// the panel) since M3-C stripped the panel down to input + result.
    static func outputLanguage() -> OutputLanguage {
        let stored = UserDefaults.standard.string(forKey: outputLanguageKey)
        return stored.flatMap(OutputLanguage.init(rawValue:)) ?? .japanese
    }

    static func selectedModel() -> ReviewModel {
        ReviewModel.find(id: UserDefaults.standard.string(forKey: selectedModelKey))
    }

    static func selectedVisionModelID() -> String {
        let stored = UserDefaults.standard.string(forKey: selectedVisionModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored?.isEmpty == false ? stored! : defaultVisionModelID
    }

    static func isHistoryEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: isHistoryEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: isHistoryEnabledKey)
    }

    /// L1 situational context capture (frontmost app + surrounding text).
    /// Default ON; the panel chip lets the user exclude it per session.
    static func isContextCaptureEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: isContextCaptureEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: isContextCaptureEnabledKey)
    }

    /// L2/L3 memory (persona/relationship cards): injection into reviews and
    /// post-deploy distillation. Default ON; cards remain editable either way.
    static func isMemoryEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: isMemoryEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: isMemoryEnabledKey)
    }

    /// Screen navigator (streaming chat over screenshots) instead of the
    /// legacy one-shot vision interpretation. Gateway-only; the legacy path
    /// also remains the fallback for signed-out/BYOK sessions.
    static func isNavigatorEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: isNavigatorEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: isNavigatorEnabledKey)
    }

    /// Auto first turn of the navigator (scene recognition fired at capture,
    /// before the user asks anything). Kept toggleable on purpose: whether
    /// the one-liner beats "just ask" is an open question to be measured
    /// (docs/navigator-copilot-plan.md §9-b).
    static func isNavigatorAutoFirstTurnEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: isNavigatorAutoFirstTurnEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: isNavigatorAutoFirstTurnEnabledKey)
    }
}
