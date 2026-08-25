import SwiftUI

/// Thin Phase 3-a surface: renders ComposeSession state and forwards actions.
struct FoundationComposeRootView: View {
    @ObservedObject var session: ComposeSession
    @ObservedObject private var authViewModel = AuthViewModel.shared
    let onExpansionChange: (Bool) -> Void

    var body: some View {
        Group {
            if authViewModel.hasSession {
                ComposeSessionView(
                    session: session,
                    onExpansionChange: onExpansionChange
                )
            } else {
                LoginRequiredView(
                    viewModel: authViewModel,
                    config: BombSquadConfig.snapshot()
                )
            }
        }
        .panelChrome()
    }
}

struct ComposeSessionView: View {
    @ObservedObject var session: ComposeSession
    @ObservedObject private var noticeCenter = OperationalNoticeCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showHelp = false
    @AppStorage(AppSettings.isProactiveSuggestEnabledKey)
    private var isProactiveSuggestEnabled = true
    let onExpansionChange: (Bool) -> Void

    private var focusedField: Binding<FocusField?> {
        Binding(get: { session.focusedField }, set: { session.focusedField = $0 })
    }

    /// The lower slot is shared by the review result and the proactive
    /// suggestion — mutually exclusive, so a review always wins the space.
    private var hasReviewSurface: Bool {
        session.result != nil || !(session.streamingRevision ?? "").isEmpty
    }

    private var showsExpandedContent: Bool {
        hasReviewSurface || isProactiveSuggestEnabled || session.suggestionStatus == .ready
    }

    var body: some View {
        VStack(spacing: 0) {
            globalMessages

            draftPane
                .frame(maxHeight: showsExpandedContent ? 190 : .infinity)

            lowerSlot
                .frame(maxHeight: showsExpandedContent ? .infinity : nil)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.28), value: showsExpandedContent)
        .frame(minWidth: 620, minHeight: showsExpandedContent ? 640 : 360)
        .onAppear {
            DispatchQueue.main.async { session.focusedField = .draft }
            onExpansionChange(showsExpandedContent)
        }
        .onChange(of: showsExpandedContent) { _, expanded in
            onExpansionChange(expanded)
        }
    }

    private var draftPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                composeToolInfo
            }

            // The microphone sits in the field, not in the toolbar below it.
            // It used to appear only once recording had started, and outside
            // the form — so the one sign that dictation existed showed up after
            // you had already found it some other way.
            HStack(alignment: .bottom, spacing: 0) {
                SendableTextEditor(
                    text: $session.draft,
                    focusedField: focusedField,
                    field: .draft,
                    onSend: session.deployDraft
                )
                .padding(8)

                DictationButton(
                    isRecording: session.isRecording,
                    isTranscribing: session.isTranscribing,
                    action: { session.onToggleDictation?() }
                )
                .padding(.trailing, 10)
                .padding(.bottom, 10)
            }
            .background(EditorFocusBackground(
                isFocused: session.focusedField == .draft && session.canFocusRevision
            ))

            HStack(spacing: 8) {
                Button {
                    showHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("使い方を表示します")
                .accessibilityLabel("使い方")
                .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("使い方").font(.headline)
                        shortcut("Enter", "送信")
                        shortcut("Shift+Enter", "改行")
                        shortcut("\(KeybindingSettings.gestureKey().hintLabel) ×1", "文案とフォーカス切替")
                        shortcut("\(KeybindingSettings.gestureKey().hintLabel) ×2", "起動 / ビジョン / 閉じる")
                        shortcut("\(KeybindingSettings.gestureKey().hintLabel) 長押し", "音声（マイクのクリックでも可）")
                        shortcut("Esc", "閉じる")
                        Text("レビューは「レビュー」ボタンで実行します。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }

                // Recording and transcribing are shown by the microphone in
                // the field. A second indicator here said the same thing in
                // another place, which is how a user learns to look somewhere
                // other than the control they pressed.

                Spacer(minLength: 12)

                if session.isReviewing {
                    processingStatus("レビュー中")
                }

                Button(action: session.requestReview) {
                    Label("レビュー", systemImage: "checkmark.shield")
                }
                .disabled(!session.canReview)

                PanelSendButton(
                    accessibilityLabel: "入力文を送信",
                    help: "入力文を送信（Enter）",
                    isEnabled: session.canDeployDraft,
                    action: session.deployDraft
                )
            }
        }
        .padding()
    }

    @ViewBuilder
    private var globalMessages: some View {
        if session.errorMessage != nil || noticeCenter.current != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let error = session.errorMessage {
                    ErrorBanner(message: error)
                }
                if let notice = noticeCenter.current {
                    OperationalNoticeBanner(
                        message: notice.message,
                        onDismiss: noticeCenter.dismiss
                    )
                }
            }
            .padding(.horizontal)
            .padding(.top)
        }
    }

    @ViewBuilder
    private var lowerSlot: some View {
        if hasReviewSurface {
            reviewPane
        } else {
            suggestionPane
        }
    }

    private var suggestionPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("自動返信モード", systemImage: "sparkles")
                    .font(.headline)
                Toggle("", isOn: $isProactiveSuggestEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(isProactiveSuggestEnabled ? "自動返信モードをオフにする" : "自動返信モードをオンにする")
                    .accessibilityLabel("自動返信モード")
                Spacer()
            }
            .background(WindowDragHandle())
            .onChange(of: isProactiveSuggestEnabled) { _, enabled in
                AppCommandCenter.shared.notifyProactiveSuggestionSettingChanged(enabled)
            }

            if isProactiveSuggestEnabled || session.suggestionStatus == .ready {
                switch session.suggestionStatus {
                case .preparing:
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("画面を分析しています…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .ready:
                    SendableTextEditor(
                        text: $session.suggestedDraft,
                        focusedField: focusedField,
                        field: .revision,
                        onSend: session.deploySuggestion
                    )
                    .padding(8)
                    .frame(maxHeight: .infinity)
                    .background(EditorFocusBackground(isFocused: session.focusedField == .revision))

                    if let note = session.suggestionNote, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Spacer()
                        PanelSendButton(
                            accessibilityLabel: "AI文案を送信",
                            help: "AI文案を送信（Enter）",
                            isEnabled: session.hasSuggestion,
                            action: session.deploySuggestion
                        )
                    }

                case .unavailable, .idle:
                    VStack(alignment: .leading, spacing: 8) {
                        if session.suggestionStatus == .idle {
                            Text("自動返信モードを準備しています。")
                                .foregroundStyle(.secondary)
                        } else if let errorMessage = session.suggestionErrorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
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
                            Text("この画面に合わせた文案は出せませんでした。")
                                .foregroundStyle(.secondary)
                        }
                        Text("自分で入力して送信できます。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
                    .background(EditorFocusBackground(isFocused: false))
                }

                if let question = session.factQuestion {
                    FactQuestionRow(
                        question: question,
                        state: session.factQuestionState,
                        onAnswer: session.answerFactQuestion(accepted:)
                    )
                }
            }
        }
        .padding()
    }

    private var reviewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("レビュー", systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer()
                if let ms = session.lastDurationMs {
                    Text("\(session.lastModelName ?? "") · \(ms) ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .background(WindowDragHandle())

            if let result = session.result {
                reviewedResult(result)
            } else if let streaming = session.streamingRevision, !streaming.isEmpty {
                streamingResult(streaming)
            }
        }
        .padding()
    }

    private func reviewedResult(_ result: ReviewResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.needsReReview {
                Label("原文が変更されました。「レビュー」ボタンで再レビューできます。",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            SendableTextEditor(
                text: $session.revisedDraft,
                focusedField: focusedField,
                field: .revision,
                onSend: session.deployRevision
            )
            .padding(8)
            .frame(maxHeight: .infinity)
            .background(EditorFocusBackground(isFocused: session.focusedField == .revision))

            HStack {
                Spacer()
                PanelSendButton(
                    accessibilityLabel: "レビュー文案を送信",
                    help: "レビュー文案を送信（Enter）",
                    isEnabled: !session.revisedDraft.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                    action: session.deployRevision
                )
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(result.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    DiffView(original: session.draft, revised: session.revisedDraft)
                        .frame(minHeight: 96, maxHeight: 180)
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
            .frame(maxHeight: 300)
        }
    }

    private func streamingResult(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
            }
            .background(EditorFocusBackground(isFocused: false))
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("生成中…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func shortcut(_ key: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(key).font(.caption.monospaced()).frame(width: 96, alignment: .leading)
            Text(action).font(.caption)
        }
    }

    private func processingStatus(_ title: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)です")
    }

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
/// sits below the draft, never takes focus, and ignoring it is a complete
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
