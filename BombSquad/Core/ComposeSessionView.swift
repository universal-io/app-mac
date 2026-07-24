import SwiftUI

/// Thin Phase 3-a surface: renders ComposeSession state and forwards actions.
struct FoundationComposeRootView: View {
    @ObservedObject var session: ComposeSession
    @ObservedObject private var authViewModel = AuthViewModel.shared

    var body: some View {
        Group {
            if authViewModel.hasSession {
                ComposeSessionView(session: session)
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
    @State private var showHelp = false
    @State private var isInputHistoryExpanded = false

    private var focusedField: Binding<FocusField?> {
        Binding(get: { session.focusedField }, set: { session.focusedField = $0 })
    }

    /// The lower slot is shared by the review result and the proactive
    /// suggestion — mutually exclusive, so a review always wins the space.
    private var hasReviewSurface: Bool {
        session.result != nil || session.isReviewing
    }

    private var hasSuggestionSurface: Bool {
        session.suggestionStatus == .preparing || session.suggestionStatus == .ready
    }

    private var showsLowerSlot: Bool {
        hasReviewSurface || hasSuggestionSurface
    }

    var body: some View {
        VStack(spacing: 0) {
            globalMessages

            draftPane
                .frame(maxHeight: showsLowerSlot ? 190 : .infinity)

            if showsLowerSlot {
                lowerSlot
                    .frame(maxHeight: .infinity)
            }
        }
        .animation(.spring(duration: 0.35), value: showsLowerSlot)
        .frame(minWidth: 620, minHeight: 640)
        .task { await session.loadRecentHistoryIfNeeded() }
        .onAppear {
            DispatchQueue.main.async { session.focusedField = .draft }
        }
    }

    private var draftPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let context = session.situationalContext, !session.isContextExcluded {
                FoundationContextChip(context: context, onExclude: session.excludeContext)
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
                        shortcut("Enter", "確定")
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
                } else if session.isReviewing {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button(action: session.requestReview) {
                    Label("レビュー", systemImage: "checkmark.shield")
                }
                .disabled(!session.canReview)

                Button(action: session.deployDraft) {
                    Label("確定", systemImage: "paperplane.fill")
                }
                .disabled(!session.canDeployDraft)
                .buttonStyle(.borderedProminent)
            }

            if session.isEmptyDraft, !session.recentHistoryEntries.isEmpty {
                inputHistory
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
                Label("文案", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if session.suggestionStatus == .preparing {
                    ProgressView().controlSize(.small)
                }
            }
            .background(WindowDragHandle())

            if session.suggestionStatus == .preparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("画面を読み取って文案を準備中…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
                .background(EditorFocusBackground(isFocused: false))
            } else {
                SendableTextEditor(
                    text: $session.suggestedDraft,
                    focusedField: focusedField,
                    field: .revision,
                    onSend: session.adoptSuggestion
                )
                .padding(8)
                .frame(maxHeight: .infinity)
                .background(EditorFocusBackground(isFocused: session.focusedField == .revision))

                if let note = session.suggestionNote, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("使わなければ保存されません。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button(action: session.dismissSuggestion) {
                        Label("破棄", systemImage: "xmark")
                    }
                    .buttonStyle(.borderless)
                    Button(action: session.adoptSuggestion) {
                        Label("採用", systemImage: "arrow.up.left")
                    }
                    .buttonStyle(.borderedProminent)
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
            } else if session.isReviewing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("レビュー中…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
                .background(EditorFocusBackground(isFocused: false))
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
                Button(action: session.deployRevision) {
                    Label("確定", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
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

    private var inputHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isInputHistoryExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text("入力履歴")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: isInputHistoryExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isInputHistoryExpanded ? "入力履歴を閉じる" : "入力履歴を開く")

            if isInputHistoryExpanded {
                ForEach(session.recentHistoryEntries) { entry in
                    Button {
                        session.restoreHistoryEntry(entry)
                        isInputHistoryExpanded = false
                    } label: {
                        HStack {
                            Text(entry.finalText)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.left")
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("原文欄に入力します")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func shortcut(_ key: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(key).font(.caption.monospaced()).frame(width: 96, alignment: .leading)
            Text(action).font(.caption)
        }
    }
}

struct FoundationContextChip: View {
    let context: SituationalContext
    let onExclude: () -> Void
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showDetail.toggle()
            } label: {
                Label(context.chipLabel, systemImage: "paperclip")
                    .font(.caption)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("参照中の周辺コンテクスト").font(.headline)
                    Text(context.chipLabel).font(.caption).foregroundStyle(.secondary)
                    if let excerpt = context.conversationExcerpt, !excerpt.isEmpty {
                        ScrollView {
                            Text(excerpt)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: 380, height: 220)
                    }
                    Text("この情報は保存されず、このセッションのレビューにだけ使われます。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            Button(action: onExclude) {
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("このセッションでは周辺コンテクストを使いません")
            .accessibilityLabel("周辺コンテクストを除外")
            Spacer()
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
