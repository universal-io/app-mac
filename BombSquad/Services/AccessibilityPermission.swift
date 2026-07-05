import AppKit
import ApplicationServices

/// Accessibility permission is required to post synthetic key events (⌘V) into
/// other apps. The grant persists across rebuilds because the app is signed with
/// a stable Development certificate.
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Returns current trust state and, when untrusted, opens the system prompt
    /// guiding the user to System Settings → Privacy & Security → Accessibility.
    @discardableResult
    static func prompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
