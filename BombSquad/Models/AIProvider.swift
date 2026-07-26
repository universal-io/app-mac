import Foundation

enum AppSettings {
    static let isHistoryEnabledKey = "isHistoryEnabled"
    static let isContextCaptureEnabledKey = "isContextCaptureEnabled"
    static let isProactiveSuggestEnabledKey = "isProactiveSuggestEnabled"
    static let outputLanguageKey = "outputLanguage"
    static let localHistoryLimit = 100

    /// The user's choice, or what their Mac implies until they make one.
    static func outputLanguage() -> OutputLanguage {
        let stored = UserDefaults.standard.string(forKey: outputLanguageKey)
        return stored.flatMap(OutputLanguage.init(rawValue:)) ?? .systemDefault
    }

    static func isHistoryEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: isHistoryEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: isHistoryEnabledKey)
    }

    static func isContextCaptureEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: isContextCaptureEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: isContextCaptureEnabledKey)
    }

    static func isProactiveSuggestEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: isProactiveSuggestEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: isProactiveSuggestEnabledKey)
    }
}
