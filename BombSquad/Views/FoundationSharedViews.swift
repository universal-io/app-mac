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

/// "See → understand → respond": situation first, then requests,
/// prepared actions, and finally the extracted source as reference material.
struct TransformInterpretationView: View {
    let result: TransformInterpretationResult
    var isTransform: Bool = false
    let onApprove: (TransformSuggestedAction) -> Void
    let onEdit: (TransformSuggestedAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("状況", systemImage: "text.magnifyingglass") {
                    Text(result.situation)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !result.asks.isEmpty {
                    section("求められていること", systemImage: "checklist") {
                        bulletList(result.asks)
                    }
                }

                if !result.suggestedActions.isEmpty {
                    section("提案アクション", systemImage: "wand.and.stars") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(result.suggestedActions) { action in
                                FoundationSuggestedActionCard(
                                    action: action,
                                    isTransform: isTransform,
                                    onApprove: { onApprove(action) },
                                    onEdit: { onEdit(action) }
                                )
                            }
                        }
                    }
                }

                if !result.extracted.isEmpty {
                    section("読み取った内容", systemImage: "text.viewfinder") {
                        Text(result.extracted)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(EditorFocusBackground(isFocused: false))
    }

    private func section<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .bold()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(item)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }
}

private struct FoundationSuggestedActionCard: View {
    let action: TransformSuggestedAction
    var isTransform: Bool
    let onApprove: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(action.kind.label)
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(kindColor.opacity(0.2), in: Capsule())
                    .foregroundStyle(kindColor)
                Text(action.title)
                    .font(.callout).bold()
                Spacer()
            }

            if action.hasDraft {
                Text(action.draft)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Spacer()
                    if !isTransform {
                        Button(action: onEdit) {
                            Label("編集する", systemImage: "square.and.pencil")
                        }
                        .help("文案を原文エディタに引き継いで編集します")
                    }

                    if isTransform {
                        Button(action: onApprove) {
                            Label("承認してコピー", systemImage: "doc.on.clipboard.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("この文案をクリップボードにコピーします（相手には送信されません）")
                    } else {
                        PanelSendButton(
                            accessibilityLabel: action.kind == .reply
                                ? "返信文案を送信"
                                : "文案を入力",
                            help: "この文案を呼び出し元のフィールドへ入力します",
                            isEnabled: true,
                            action: onApprove
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var kindColor: Color {
        switch action.kind {
        case .reply: return .blue
        case .fillForm: return .teal
        case .task: return .orange
        case .infoOnly: return .secondary
        }
    }
}
