import SwiftUI

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

/// A successful request that recovered from an error must not look identical
/// to a clean request. The user can dismiss the notice after reading it.
///
/// These operational notices are developer-facing diagnostics. Owner decision
/// 2026-07-15: they must be hidden or gated behind a developer setting before
/// public release; end users must never see them.
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

                    Button(action: onApprove) {
                        Label(
                            isTransform
                                ? "承認してコピー"
                                : action.kind == .reply ? "承認して送信" : "承認して入力",
                            systemImage: isTransform ? "doc.on.clipboard.fill" : "paperplane.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .help(isTransform
                            ? "この文案をクリップボードにコピーします（相手には送信されません）"
                            : "この文案をそのまま呼び出し元のフィールドへ入力します")
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
