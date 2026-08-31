import SwiftUI

/// Thin surface root: the compose bubble when signed in, the sign-in card in
/// the same chrome otherwise.
struct FoundationComposeRootView: View {
    @ObservedObject var session: ComposeSession
    @ObservedObject private var authViewModel = AuthViewModel.shared
    /// How much room the growing surfaces may take, decided by the caller from
    /// the screen the bubble is on — same contract as Vision's bubble.
    let heightBudget: CGFloat
    let onClose: () -> Void

    var body: some View {
        Group {
            if authViewModel.hasSession {
                ComposeBubbleView(
                    session: session,
                    heightBudget: heightBudget,
                    onClose: onClose
                )
            } else {
                LoginRequiredView(
                    viewModel: authViewModel,
                    config: BombSquadConfig.snapshot()
                )
                .frame(width: VisionPointingOverlay.bubbleWidth)
                .background(WindowDragHandle())
                .bubbleChrome()
            }
        }
    }
}

/// Compose, as the same companion bubble Vision speaks from.
///
/// R14 put Vision's answer beside the thing it is about; this is the same card
/// beside the field the user is writing into. The base of the surface is input
/// completion: one field, the microphone inside it, Enter to send — no send
/// button, exactly as the Vision bubble settled it. The two AI features are
/// deliberately below that base: レビュー and 自動返信 are buttons under the
/// field, and neither runs by itself unless the auto-reply toggle in the
/// handle says so. A surface that starts working uninvited is what the old
/// panel did, and most summons want none of it.
struct ComposeBubbleView: View {
    @ObservedObject var session: ComposeSession
    @ObservedObject private var noticeCenter = OperationalNoticeCenter.shared
    @ObservedObject private var availability = GatewayAvailability.shared
    let heightBudget: CGFloat
    let onClose: () -> Void

    /// Off by default: the always-on behaviour is the exception somebody opts
    /// into, not the resting state of an input surface.
    @AppStorage(AppSettings.isProactiveSuggestEnabledKey)
    private var isProactiveSuggestEnabled = false
    @State private var draftContentHeight: CGFloat = VisionBubbleView.inputMinHeight
    @State private var resultContentHeight: CGFloat = VisionBubbleView.inputMinHeight

    private static let resultFontSize: CGFloat = 13

    /// Everything that is not a growing surface, at its tallest: the handle
    /// (44), the body's padding (24), the row gaps (~50), the reviewed-draft
    /// chip at three lines (~60), the action row (28), a note line (~20) and
    /// the margin the placement keeps on both edges (24). Rounded up — being
    /// wrong low is what pushes a bubble past the screen.
    static let chromeHeight: CGFloat = 260

    /// How much height the growing surfaces (result editor, review detail,
    /// input field) may share on this screen. Each takes at most a third of
    /// it, so the three together never outgrow the whole.
    static func heightBudget(visibleHeight: CGFloat) -> CGFloat {
        max(150, visibleHeight - chromeHeight)
    }

    /// How tall the review detail (summary, diff, issues) may grow before it
    /// scrolls. Reference material: the field being written is the surface
    /// that deserves the room.
    static func detailHeight(within budget: CGFloat) -> CGFloat {
        max(96, min(240, budget / 3))
    }

    private var focusedField: Binding<FocusField?> {
        Binding(get: { session.focusedField }, set: { session.focusedField = $0 })
    }

    /// The result slot is shared by the review and the suggestion — mutually
    /// exclusive, the review winning while it exists (an explicit 自動返信
    /// press takes it back through `takeDownReviewSurface`).
    private var hasReviewSurface: Bool {
        session.result != nil
            || !(session.streamingRevision ?? "").isEmpty
            || session.isReviewing
    }

    /// Whether a second editor exists for focus to alternate with. With one
    /// field there is nothing to tell apart, so the focus ring stays quiet.
    private var hasSecondField: Bool {
        session.canFocusRevision || session.suggestionStatus == .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            handle
            VStack(alignment: .leading, spacing: 10) {
                messages
                if hasReviewSurface {
                    reviewSurface
                } else {
                    suggestionSurface
                }
                if let question = session.factQuestion {
                    FactQuestionRow(
                        question: question,
                        state: session.factQuestionState,
                        onAnswer: session.answerFactQuestion(accepted:)
                    )
                }
                draftField
                actions
            }
            .padding(12)
        }
        .frame(width: VisionPointingOverlay.bubbleWidth, alignment: .leading)
        // Same grip rule as the Vision bubble: everything that is not a control
        // or a field is a place to pick the card up by.
        .background(WindowDragHandle())
        .bubbleChrome()
        .onAppear {
            DispatchQueue.main.async { session.focusedField = .draft }
        }
    }

    // MARK: - Handle

    /// Tool and info on the left, the auto-reply toggle and the named close on
    /// the right. No state chip: Compose has one state, and a chip that names
    /// the only thing the card can be would look like Vision's mode chip while
    /// meaning nothing.
    private var handle: some View {
        HStack(spacing: 8) {
            composeToolInfo
            Spacer(minLength: 0)
            autoReplyToggle
            Button(action: onClose) {
                HStack(spacing: 5) {
                    Label("閉じる", systemImage: "xmark")
                        .font(.system(size: 11))
                    Text("Esc")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("閉じる")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// The always-on switch, in the top corner the way the user asked for it:
    /// a mode that generates on every summon should be visible wherever it is
    /// in effect, and cheap to leave.
    private var autoReplyToggle: some View {
        HStack(spacing: 4) {
            Text("自動返信")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Toggle("", isOn: $isProactiveSuggestEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("自動返信モード")
        }
        .help(isProactiveSuggestEnabled
            ? "オンの間は、開いた瞬間に返信文案を自動で用意します"
            : "自動返信モードはオフです。「自動返信」ボタンでその場で作れます")
        .onChange(of: isProactiveSuggestEnabled) { _, enabled in
            AppCommandCenter.shared.notifyProactiveSuggestionSettingChanged(enabled)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let refusal = availability.refusal {
            ServiceRefusalBanner(message: refusal)
        }
        // An error that only repeats the standing refusal is the same sentence
        // twice in one bubble, which reads as two separate problems.
        if let error = session.errorMessage, error != availability.refusal {
            ErrorBanner(message: error)
        }
        if let notice = noticeCenter.current {
            OperationalNoticeBanner(
                message: notice.message,
                onDismiss: noticeCenter.dismiss
            )
        }
    }

    // MARK: - Review

    @ViewBuilder
    private var reviewSurface: some View {
        // The sentence the review is about, as the user's own speech — the
        // same chip Vision shows for a sent question, in the same purple. The
        // full text is still in the field below; three lines here identify the
        // subject rather than store it.
        if let reviewed = session.reviewedDraft, !reviewed.isEmpty {
            Text(reviewed)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(3)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(MarkStyle.swiftUIColor, in: RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
                .accessibilityLabel("レビューした原文: \(reviewed)")
        }

        if let result = session.result {
            if session.needsReReview {
                Label(
                    "原文が変更されました。「レビュー」でやり直せます。",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            resultEditor(
                text: $session.revisedDraft,
                onSend: session.deployRevision,
                accessibilityLabel: "レビュー文案"
            )
            reviewDetail(result)
        } else if let streaming = session.streamingRevision, !streaming.isEmpty {
            ScrollView {
                Text(streaming)
                    .font(.system(size: Self.resultFontSize))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: Self.detailHeight(within: heightBudget))
            .padding(10)
            .background(readingBackground)
        } else if session.isReviewing {
            Label("入力文を確認しています…", systemImage: "checkmark.shield")
                .font(.system(size: Self.resultFontSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
                .background(readingBackground)
        }
    }

    private func reviewDetail(_ result: ReviewResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(result.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                DiffView(original: session.draft, revised: session.revisedDraft)
                    .frame(minHeight: 72, maxHeight: 150)
                if result.issues.isEmpty {
                    Label("指摘はありません。そのまま送れます。", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                } else {
                    ForEach(result.sortedIssues) { issue in
                        ComposeIssueCard(issue: issue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Self.detailHeight(within: heightBudget))
        .padding(10)
        .background(readingBackground)
    }

    // MARK: - Suggestion

    /// Nothing at rest. The old panel reserved this area whenever the mode was
    /// on; the bubble shows a surface only when there is something on it, so an
    /// ordinary summon is the field and two buttons and nothing else.
    @ViewBuilder
    private var suggestionSurface: some View {
        switch session.suggestionStatus {
        case .idle:
            EmptyView()
        case .preparing:
            Label("画面を分析しています…", systemImage: "eye")
                .font(.system(size: Self.resultFontSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
                .background(readingBackground)
        case .ready:
            resultEditor(
                text: $session.suggestedDraft,
                onSend: session.deploySuggestion,
                accessibilityLabel: "AI文案"
            )
            if let note = session.suggestionNote, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .unavailable:
            VStack(alignment: .leading, spacing: 6) {
                if let message = session.suggestionErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = session.suggestionErrorDetail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("この画面に合わせた文案は出せませんでした。自分で入力して送信できます。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
            .background(readingBackground)
        }
    }

    // MARK: - Fields

    /// The AI's editable output — review revision or suggested reply, never
    /// both. Enter sends it; it can be reworked in place first.
    private func resultEditor(
        text: Binding<String>,
        onSend: @escaping () -> Void,
        accessibilityLabel: String
    ) -> some View {
        SendableTextEditor(
            text: text,
            focusedField: focusedField,
            field: .revision,
            onSend: onSend,
            onContentHeightChange: { height in
                guard abs(height - resultContentHeight) > 0.5 else { return }
                resultContentHeight = height
            }
        )
        .frame(height: VisionBubbleView.inputHeight(
            content: resultContentHeight,
            within: heightBudget
        ))
        .background(typingBackground(focused: session.focusedField == .revision))
        .accessibilityLabel(accessibilityLabel)
        .help("Enterで送信、Shift+Enterで改行")
    }

    private var draftField: some View {
        HStack(alignment: .bottom, spacing: 0) {
            SendableTextEditor(
                text: $session.draft,
                focusedField: focusedField,
                field: .draft,
                onSend: session.deployDraft,
                onContentHeightChange: { height in
                    guard abs(height - draftContentHeight) > 0.5 else { return }
                    draftContentHeight = height
                }
            )
            .frame(height: VisionBubbleView.inputHeight(
                content: draftContentHeight,
                within: heightBudget
            ))
            DictationButton(
                isRecording: session.isRecording,
                isTranscribing: session.isTranscribing,
                action: { session.onToggleDictation?() }
            )
            .padding(.trailing, 8)
            .padding(.bottom, 7)
        }
        .background(typingBackground(
            focused: hasSecondField && session.focusedField == .draft
        ))
        .accessibilityLabel("入力文")
        .help("Enterで送信、Shift+Enterで改行")
    }

    // MARK: - Actions

    /// The two AI features, side by side under the field the user asked for.
    /// Both are invitations rather than states: pressing one runs it once, on
    /// whatever is on screen and in the field right now.
    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: session.requestReview) {
                HStack(spacing: 5) {
                    if session.isReviewing {
                        ProgressView().controlSize(.mini)
                    }
                    Label("レビュー", systemImage: "checkmark.shield")
                        .font(.system(size: 11))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!session.canReview)
            .help("いま入力されている文をレビューします")
            .accessibilityLabel("レビュー")

            Button(action: { session.onRequestSuggestion?() }) {
                HStack(spacing: 5) {
                    if session.suggestionStatus == .preparing {
                        ProgressView().controlSize(.mini)
                    }
                    Label("自動返信", systemImage: "sparkles")
                        .font(.system(size: 11))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(session.suggestionStatus == .preparing)
            .help("この画面への返信文案をその場で作ります")
            .accessibilityLabel("自動返信の文案を作成")
        }
    }

    // MARK: - Surfaces

    private var readingBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(BubbleSurface.reading)
            .allowsHitTesting(false)
    }

    /// The typing surface, with the focus ring that says which field Enter
    /// will send. System accent, not the product's purple: which editor is
    /// first responder is state, and iris never lends itself to state.
    private func typingBackground(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(BubbleSurface.typing)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(focused ? 1 : 0)
            )
            .animation(.easeInOut(duration: 0.12), value: focused)
    }

    // MARK: - Tool info

    private var composeToolName: String? {
        session.activeSkillName ?? session.situationalContext?.detectedProductName
    }

    private var composeToolInfo: some View {
        PanelToolInfo(
            toolName: composeToolName,
            toolHelp: composeToolName.map {
                "\($0) を検出し、文案作成の参考にしています"
            } ?? "検出されたツールはありません",
            informationHelp: "参照情報を表示",
            informationAccessibilityLabel: "Composeの参照情報"
        ) {
            ComposeContextPopover(
                context: session.situationalContext,
                skillName: session.activeSkillName,
                includesScreenshot: session.suggestionStatus == .preparing
                    || session.suggestionStatus == .ready,
                isContextExcluded: session.isContextExcluded,
                onExclude: session.excludeContext
            )
        }
    }
}

/// The one thing the app may ask about the user in a session, asked in place
/// rather than through a settings screen nobody opens. Deliberately quiet: it
/// sits below the result, never takes focus, and ignoring it is a complete
/// answer — the gateway stops asking on its own after a few unanswered turns.
private struct FactQuestionRow: View {
    let question: FactQuestion
    let state: FactQuestionState
    let onAnswer: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)

            switch state {
            case .asking, .saving:
                Text(question.question)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if state == .saving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("はい") { onAnswer(true) }
                        .controlSize(.small)
                        .help("この内容を覚えます。あとから管理画面で編集・削除できます")
                        .accessibilityLabel("はい、覚える")
                    Button("いいえ") { onAnswer(false) }
                        .controlSize(.small)
                        .help("覚えません。この項目は次回以降たずねません")
                        .accessibilityLabel("いいえ、覚えない")
                }

            case .saved:
                Text("覚えました。管理画面で編集・削除できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)

            case .declined:
                Text("覚えません。この項目は次回以降たずねません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)

            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private struct ComposeContextPopover: View {
    let context: SituationalContext?
    var skillName: String? = nil
    var includesScreenshot = false
    let isContextExcluded: Bool
    let onExclude: () -> Void

    private var productName: String? {
        skillName ?? context?.detectedProductName
    }

    private var surroundingTextStatus: String {
        if isContextExcluded { return "使用しません" }
        return context?.hasConversation == true ? "使用中" : "取得されていません"
    }

    private var copyText: String {
        var lines = [
            "Universal I/O Compose context",
            "",
            "detected_tool: \(productName ?? "none")",
            "screen_image: \(includesScreenshot ? "used" : "not_used")",
            "surrounding_text: \(surroundingTextStatus)",
            "retention: session_only",
        ]
        if let context {
            lines += [
                "source: \(context.detectionSource)",
                "app: \(context.appName)",
                "bundle_id: \(context.bundleID ?? "none")",
                "window: \(context.windowTitle ?? "none")",
                "captured_at: \(context.capturedAt.formatted(.iso8601))",
                "",
                "[surrounding_text]",
                context.conversationExcerpt ?? "none",
            ]
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        PanelInformationPopover(
            title: "Composeの参照情報",
            copyText: copyText,
            note: "参照情報は、このセッションの文案作成とレビューのためだけに使用され、保存されません。"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let productName {
                    detailRow("検出ツール", productName)
                }
                detailRow("画面", includesScreenshot ? "自動返信の生成に使用" : "使用していません")
                detailRow("周辺テキスト", surroundingTextStatus)
                if let context {
                    detailRow("検出元", context.detectionSource)
                    detailRow("保存", "このセッションのみ")
                    if let excerpt = context.conversationExcerpt, !excerpt.isEmpty {
                        Divider()
                        Text("取得した周辺テキスト")
                            .font(.caption.weight(.semibold))
                        ScrollView {
                            Text(excerpt)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: 420, height: 220)
                    }
                }

                if !isContextExcluded, context?.hasConversation == true {
                    Button(action: onExclude) {
                        Label("このセッションでは周辺テキストを使わない", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                    .help("アクセシビリティから取得した周辺テキストをこのセッションから除外します")
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
}

private struct ComposeIssueCard: View {
    let issue: ReviewIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(issue.category.label).font(.caption.weight(.semibold))
                Text("重要度: \(issue.severity.label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !issue.excerpt.isEmpty {
                Text("「\(issue.excerpt)」").font(.callout.weight(.medium))
            }
            Text(issue.explanation).font(.callout)
            if !issue.suggestion.isEmpty {
                Text(issue.suggestion).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
