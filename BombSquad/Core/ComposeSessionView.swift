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
            if let context = session.situationalContext, !session.isContextExcluded {
                FoundationContextChip(
                    context: context,
                    skillName: session.activeSkillName,
                    includesScreenshot: session.suggestionStatus == .preparing
                        || session.suggestionStatus == .ready,
                    onExclude: session.excludeContext
                )
            }

            SendableTextEditor(
                text: $session.draft,
                focusedField: focusedField,
                field: .draft,
                onSend: session.deployDraft
            )
            .padding(8)
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
                        shortcut("\(KeybindingSettings.gestureKey().hintLabel) 長押し", "音声")
                        shortcut("Esc", "閉じる")
                        Text("レビューは「レビュー」ボタンで実行します。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }

                Button {
                    AppCommandCenter.shared.requestScreenshotCapture()
                } label: {
                    Image(systemName: "camera.viewfinder")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("ビジョン入力としてスクリーンショットを撮影します")
                .accessibilityLabel("画面を撮影して読み取る")

                if session.isRecording {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                    Text("録音中…").font(.caption).foregroundStyle(.secondary)
                } else if session.isTranscribing {
                    ProgressView().controlSize(.small)
                    Text("文字起こし中…").font(.caption).foregroundStyle(.secondary)
                }

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
                if let skillName = session.activeSkillName {
                    // A skill is injected knowledge about the app on screen. It
                    // is always named here, because knowledge the user cannot
                    // see is knowledge they cannot correct or distrust.
                    Label(skillName, systemImage: "puzzlepiece.extension")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("\(skillName) の知識を参照して文案を作成しました")
                        .accessibilityLabel("適用中のスキル: \(skillName)")
                }
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
}

struct FoundationContextChip: View {
    let context: SituationalContext
    var skillName: String? = nil
    var includesScreenshot = false
    let onExclude: () -> Void
    @State private var showDetail = false

    private var productName: String? {
        skillName ?? context.detectedProductName
    }

    private var sourceLabel: String {
        let source = includesScreenshot ? "画面＋周辺テキスト" : "周辺テキスト"
        if let productName {
            return "参照中：\(productName) · \(source)"
        }
        return "参照中：\(source)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showDetail.toggle()
            } label: {
                Label(sourceLabel, systemImage: "paperclip")
                    .font(.caption)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("参照している情報を確認")
            .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("参照している情報").font(.headline)
                    if let productName {
                        detailRow("適用スキル", productName)
                    }
                    detailRow("画面画像", includesScreenshot ? "自動返信の生成に使用" : "使用していません")
                    detailRow("周辺テキスト", "アクセシビリティから取得・使用")
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
                        .frame(width: 380, height: 220)
                    }
                    Text("周辺テキストは自動返信、レビュー、受信内容の整理にだけ使われ、保存されません。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            Button(action: onExclude) {
                Label("周辺テキストを使わない", systemImage: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("このセッションではアクセシビリティから取得した周辺テキストを使いません")
            .accessibilityLabel("周辺テキストを使わない")
            Spacer()
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
