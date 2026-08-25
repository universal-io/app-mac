import AppKit
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

/// Keeps the detected tool and its supporting information in the same trailing
/// position across Compose, Vision, and other transient panel surfaces.
struct PanelToolInfo<PopoverContent: View>: View {
    let toolName: String?
    let toolHelp: String
    let informationHelp: String
    let informationAccessibilityLabel: String
    @ViewBuilder let popoverContent: () -> PopoverContent

    @State private var isShowingInformation = false

    var body: some View {
        HStack(spacing: 8) {
            if let toolName {
                ActiveSkillLabel(skillName: toolName, help: toolHelp)
            }

            Button {
                isShowingInformation.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(informationHelp)
            .accessibilityLabel(informationAccessibilityLabel)
            .popover(isPresented: $isShowingInformation, arrowEdge: .bottom) {
                popoverContent()
            }
        }
    }
}

/// Shared popover chrome for selectable, optionally copyable panel details.
struct PanelInformationPopover<Content: View>: View {
    let title: String
    let copyText: String?
    let note: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let copyText {
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(copyText, forType: .string)
                    } label: {
                        Label("コピー", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help("表示情報をすべてコピー")
                }
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(14)
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

/// The microphone, inside the field it types into.
///
/// Dictation was hold-to-talk on a key and nothing else: no button, and the
/// only sign it existed was a red `mic.fill` that appeared *outside* the form
/// once recording had already started. A capability whose sole affordance shows
/// up after you have used it is a capability nobody finds. It sits in the field
/// now, the way every messenger does it, so it is visible before it is needed
/// and reachable by somebody who has never heard of the shortcut.
///
/// Click to start, click again to stop — the key stays hold-to-talk. Two
/// interaction models for one feature is the convention, not a compromise: a
/// held key ends when you let go, and a button has nothing to let go of.
struct DictationButton: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isTranscribing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    // Red is state, so it never borrows the product's purple
                    // (`MarkStyle`). Grey until it is doing something is the
                    // whole point: the icon has to be legible as available
                    // rather than as active.
                    .foregroundStyle(isRecording ? Color.red : Color.secondary)
                    .font(.system(size: 13))
            }
        }
        .buttonStyle(.borderless)
        .disabled(isTranscribing)
        .accessibilityLabel(isRecording ? "音声入力を停止" : "音声入力を開始")
        .help(
            isTranscribing
                ? "文字起こし中…"
                : isRecording
                    ? "録音中。クリックで停止します"
                    : "音声入力（クリック、または\(KeybindingSettings.gestureKey().hintLabel) 長押し）"
        )
    }
}
