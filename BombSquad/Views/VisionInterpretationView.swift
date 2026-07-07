import SwiftUI

/// "See → understand → respond": situation first, then what is being asked,
/// then prepared actions the user can approve. The raw extracted content comes
/// last as reference material. Shared by the vision panel (screenshot) and the
/// transform layout (received message) — one result surface for both.
struct VisionInterpretationView: View {
    let result: VisionInterpretationResult
    /// Receiving side (M4-B): approve copies instead of injecting, and the
    /// edit hand-off is hidden (the exit is clipboard-only by principle).
    var isTransform: Bool = false
    let onApprove: (VisionSuggestedAction) -> Void
    let onEdit: (VisionSuggestedAction) -> Void

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
                                SuggestedActionCard(
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

/// One proposed action. Drafted actions (reply / fill_form) close the loop
/// with two buttons: approve = deploy the draft as-is into the summon-time
/// field; edit = carry it into the compose editor. Everything else is
/// presented as guidance only — I//O never executes actions itself.
private struct SuggestedActionCard: View {
    let action: VisionSuggestedAction
    var isTransform: Bool = false
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
                        Button {
                            onEdit()
                        } label: {
                            Label("編集する", systemImage: "square.and.pencil")
                        }
                        .help("文案を原文エディタに引き継いで編集します")
                    }

                    Button {
                        onApprove()
                    } label: {
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
