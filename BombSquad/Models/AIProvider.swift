import Foundation

enum AppSettings {
    static let isHistoryEnabledKey = "isHistoryEnabled"
    static let isContextCaptureEnabledKey = "isContextCaptureEnabled"
    static let isMemoryEnabledKey = "isMemoryEnabled"
    static let outputLanguageKey = "outputLanguage"
    static let localHistoryLimit = 100

    static func outputLanguage() -> OutputLanguage {
        let stored = UserDefaults.standard.string(forKey: outputLanguageKey)
        return stored.flatMap(OutputLanguage.init(rawValue:)) ?? .japanese
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

    static func isMemoryEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: isMemoryEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: isMemoryEnabledKey)
    }
}
