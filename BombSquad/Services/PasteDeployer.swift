import AppKit
import ApplicationServices
import Carbon

/// Deploys reviewed text back into the field the user was in when they pressed
/// the hotkey: writes the text to the clipboard, dismisses our panel, re-activates
/// the original app, and synthesizes ⌘V. Works with any app that supports paste
/// (Gmail, Slack, Apple Mail, Notion, …). The clipboard write also serves as a
/// visible manual-paste fallback if Accessibility permission is unavailable.
/// The sent text deliberately remains on the clipboard; no delayed restore can
/// overwrite a copy the user makes after sending.
final class PasteDeployer: Deployer {
    private enum DeploymentError: Error {
        case clipboardWriteFailed
    }

    private let targetApp: NSRunningApplication?
    private let onDismiss: () -> Void

    init(targetApp: NSRunningApplication?, onDismiss: @escaping () -> Void) {
        self.targetApp = targetApp
        self.onDismiss = onDismiss
    }

    func deploy(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw DeploymentError.clipboardWriteFailed
        }

        guard AXIsProcessTrusted() else {
            let openSettings = Self.showManualPasteNotice(canOpenSettings: true)
            onDismiss()
            if openSettings {
                AccessibilityPermission.openSettings()
            } else {
                targetApp?.activate()
            }
            return
        }

        guard let events = Self.commandVEvents() else {
            _ = Self.showManualPasteNotice(canOpenSettings: false)
            onDismiss()
            targetApp?.activate()
            return
        }

        // Close our panel first so focus can return to the target field.
        onDismiss()

        // The panel is already dismissed and we have no other windows (accessory
        // app), so focus returns to the target app on the current Space — no
        // hide() and therefore no Space switch. Just re-activate and paste.
        let target = targetApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            target?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                events.down.post(tap: .cghidEventTap)
                events.up.post(tap: .cghidEventTap)
            }
        }
    }

    private static func commandVEvents() -> (down: CGEvent, up: CGEvent)? {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyV = CGKeyCode(kVK_ANSI_V)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return (down, up)
    }

    /// This is an actionable failure, so a modal explanation is appropriate:
    /// the user must know that nothing was pasted automatically and that the
    /// exact text is already available through the standard ⌘V command.
    private static func showManualPasteNotice(canOpenSettings: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "本文をクリップボードにコピーしました"
        alert.informativeText =
            "自動で貼り付けられなかったため、対象の入力欄で⌘Vを押してください。"
        alert.addButton(withTitle: "手動で貼り付ける")
        if canOpenSettings {
            alert.addButton(withTitle: "Accessibility設定を開く")
        }
        return alert.runModal() == .alertSecondButtonReturn
    }
}
