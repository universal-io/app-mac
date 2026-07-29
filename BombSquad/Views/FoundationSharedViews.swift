import SwiftUI

/// One consistent send affordance across every transient panel surface.
/// Callers provide a context-specific accessible name for the icon-only button.
struct PanelSendButton: View {
    let accessibilityLabel: String
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperplane.fill")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Names the skill that shaped the answer on screen. A skill is injected
/// knowledge about the product the user is looking at, and it is named wherever
/// it acts: knowledge the user cannot see is knowledge they cannot correct or
/// distrust. Every panel that consumes skills shows the same chip.
struct ActiveSkillLabel: View {
    let skillName: String
    let help: String

    var body: some View {
        Label(skillName, systemImage: "puzzlepiece.extension")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityLabel("適用中のスキル: \(skillName)")
    }
}

/// Selectable error text shared by all transient panel modes.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.red)
    }
}

/// A successful request that switched to its secondary model must not look
/// identical to a clean request. The user can dismiss the notice after reading.
struct OperationalNoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("警告を閉じる")
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.orange)
    }
}
