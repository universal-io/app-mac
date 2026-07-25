import Foundation

@MainActor
final class AppCommandCenter {
    static let shared = AppCommandCenter()

    var onShowPanelRequested: (() -> Void)?
    var onShowManagementRequested: (() -> Void)?
    var onScreenshotCaptureRequested: (() -> Void)?
    var onScreenCaptureSettingsRequested: (() -> Void)?
    var onProactiveSuggestionSettingChanged: ((Bool) -> Void)?

    private init() {}

    func requestShowPanel() {
        onShowPanelRequested?()
    }

    func requestShowManagement() {
        onShowManagementRequested?()
    }

    func requestScreenshotCapture() {
        onScreenshotCaptureRequested?()
    }

    func requestScreenCaptureSettings() {
        onScreenCaptureSettingsRequested?()
    }

    func notifyProactiveSuggestionSettingChanged(_ isEnabled: Bool) {
        onProactiveSuggestionSettingChanged?(isEnabled)
    }
}
