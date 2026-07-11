import AppKit
import SwiftUI

/// Right pane: shows the review findings, the diff, the editable revision,
/// and the "deploy to live" action.
struct ReviewPanelView: View {
    @ObservedObject var viewModel: ReviewViewModel
    /// Shared focus across both editors (drives the blue highlight).
    @Binding var focusedField: FocusField?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(headerTitle, systemImage: headerSystemImage)
                    .font(.headline)
                Spacer()
                if viewModel.mode == .transform, viewModel.visionResult != nil {
                    Button {
                        viewModel.copyVisionResult()
                    } label: {
                        Label("コピー", systemImage: "doc.on.clipboard.fill")
                    }
                    .help("整理した内容全体をクリップボードにコピーします")
                }
                if let ms = viewModel.lastDurationMs {
                    Text("\(viewModel.lastModelName ?? "") · \(ms) ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                GatewayOverrideBadge()
            }
            .background(WindowDragHandle())

            if let message = viewModel.errorMessage {
                errorBanner(message)
            }

            if viewModel.mode == .transform, let vision = viewModel.visionResult {
                // M4-B: the received message goes through the same
                // "understand → respond" view as a screenshot. Approving an
                // action copies the draft (never writes back to the sender).
                VisionInterpretationView(
                    result: vision,
                    isTransform: true,
                    onApprove: { viewModel.approveSuggestedAction($0) },
                    onEdit: { _ in }
                )
            } else if let result = viewModel.result {
                resultBody(result)
            } else if let streaming = viewModel.streamingRevision, !streaming.isEmpty {
                streamingBody(streaming)
            } else if viewModel.isLoading {
                loadingState
            } else {
                emptyState
            }
        }
        .padding()
        .animation(.easeInOut(duration: 0.18), value: viewModel.result != nil)
        .animation(.easeInOut(duration: 0.18), value: viewModel.isLoading)
        .overlay(alignment: .bottom) {
            if viewModel.didDeploy {
                Label(viewModel.mode == .transform ? "クリップボードにコピーしました" : "入力先へ確定しました",
                      systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.green.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: viewModel.didDeploy)
        .task {
            await viewModel.loadRecentHistoryIfNeeded()
        }
    }

    @ViewBuilder
    private func resultBody(_ result: ReviewResult) -> some View {
        if viewModel.needsReReview {
            Label("原文が変更されました。原文で 右Shift2回 すると再レビューします。",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        // Result editor on top, aligned with the original editor on the left
        // (both sit directly under their column header).
        // Enter sends the review result (after the IME confirms any in-progress
        // conversion); Shift+Enter inserts a newline.
        SendableTextEditor(
            text: $viewModel.revisedDraft,
            focusedField: $focusedField,
            field: .revision,
            onSend: { viewModel.deployRevision() },
            onEscape: { viewModel.requestPanelClose() }
        )
            .padding(8)
            .frame(maxHeight: .infinity)
            .background(EditorFocusBackground(isFocused: focusedField == .revision))

        HStack {
            Spacer()
            Button {
                viewModel.deployRevision()
            } label: {
                // Receiving side never sends back to the sender; it only copies
                // the readable version to the clipboard for the reader's own use.
                Label(viewModel.mode == .transform ? "コピー" : "確定",
                      systemImage: viewModel.mode == .transform ? "doc.on.clipboard.fill" : "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
        }

        Divider()

        // The process below the result, diff first: "what changed and why"
        // must be readable in one second (design principle 3.5).
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(result.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The original→revision diff only makes sense when editing one's
                // own outgoing draft. On the receiving side we are not correcting
                // the sender's text, so showing a diff is meaningless (and reads
                // as if we were rewriting them). Hide it in transform mode.
                if viewModel.mode != .transform {
                    DiffView(original: viewModel.draft, revised: viewModel.revisedDraft)
                        .frame(minHeight: 96, maxHeight: 180)
                }

                if result.issues.isEmpty {
                    Label(viewModel.mode == .transform
                            ? "取り除いたノイズはありませんでした。"
                            : "指摘はありません。そのまま送れます。",
                          systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(result.sortedIssues) { IssueCard(issue: $0, mode: viewModel.mode) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
    }

    /// Live preview of the revised text while it streams from the gateway.
    /// Read-only until the final event lands and the editable editor takes over.
    private func streamingBody(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(EditorFocusBackground(isFocused: false))

            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("生成中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    /// While the (auto-)review runs, fill the result field with a spinner so the
    /// one-stop receiving flow shows progress the instant the panel opens.
    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(viewModel.mode == .transform ? "読みやすく整理しています…" : "レビュー中…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(EditorFocusBackground(isFocused: false))
    }

    /// Before any review exists, show the (non-editable) result field with a
    /// faint placeholder, mirroring the left editor's frame so the layout is
    /// stable once a result fills it in.
    private var emptyState: some View {
        Group {
            if viewModel.mode == .compose, !viewModel.recentHistoryEntries.isEmpty {
                recentHistoryState
            } else if viewModel.mode == .compose, viewModel.isLoadingRecentHistory {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("履歴を読み込み中…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
                .background(EditorFocusBackground(isFocused: false))
            } else if viewModel.mode == .compose {
                Text("レビュー結果がここに表示されます\n\nまだ履歴がありません。")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
                    .background(EditorFocusBackground(isFocused: false))
            } else {
                Text("レビュー結果がここに表示されます")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
                    .background(EditorFocusBackground(isFocused: false))
            }
        }
    }

    private var recentHistoryState: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(viewModel.recentHistoryEntries) { entry in
                Button {
                    viewModel.applyRecentHistory(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(Self.recentHistoryFormatter.string(from: entry.createdAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.usedReview ? "レビューあり" : "レビューなし")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        Text(entry.finalText)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(3)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(EditorFocusBackground(isFocused: false))
    }

    private var headerTitle: String {
        if viewModel.mode == .compose, viewModel.result == nil, !viewModel.isLoading {
            return "最近の履歴"
        }
        return viewModel.mode == .transform ? "読み取り結果" : "レビュー結果"
    }

    private var headerSystemImage: String {
        if viewModel.mode == .compose, viewModel.result == nil, !viewModel.isLoading {
            return "clock.arrow.circlepath"
        }
        return viewModel.mode == .transform ? "doc.text.magnifyingglass" : "text.magnifyingglass"
    }

    private static let recentHistoryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()

    private func errorBanner(_ message: String) -> some View {
        ErrorBanner(message: message)
    }
}

/// Clock button + popover with recent navigator sessions (view + copy only:
/// the screen has moved on, so past sessions are never resumed). Lives next
/// to the question input; keeps its own state so the live session is never
/// disturbed.
private struct NavigatorHistoryButton: View {
    @State private var isPresented = false
    @State private var records: [NavigatorSessionRecord] = []
    @State private var selected: NavigatorSessionRecord?

    var body: some View {
        Button {
            Task {
                records = await NavigatorSessionStore.shared.recent()
                selected = nil
                isPresented = true
            }
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 15))
        }
        .buttonStyle(.borderless)
        .help("過去のセッション（直近\(NavigatorSessionStore.sessionLimit)件・閲覧とコピーのみ）")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            popoverContent
                .frame(width: 460, height: 400)
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        if let selected {
            VStack(spacing: 8) {
                HStack {
                    Button {
                        self.selected = nil
                    } label: {
                        Label("一覧へ", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    Text(Self.relative(selected.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                TranscriptTextView(
                    turns: selected.turns.map {
                        NavigatorDisplayTurn(
                            role: NavigateTurn.Role(rawValue: $0.role) ?? .assistant,
                            text: $0.text
                        )
                    },
                    streamingText: nil
                )
            }
            .padding(12)
        } else if records.isEmpty {
            Text("保存されたセッションはまだありません")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(records) { record in
                Button {
                    selected = record
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title)
                            .lineLimit(1)
                        Text(Self.relative(record.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Tiny badge shown next to the model info when the gateway is overridden
/// away from the production default (e.g. localhost during development).
/// Replaces the old full-width orange banner, which was visually too loud.
struct GatewayOverrideBadge: View {
    var body: some View {
        if BombSquadConfig.isUsingOverriddenGateway() {
            Text("開発GW")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange, in: Capsule())
                .help("開発Gatewayに接続中: \(BombSquadConfig.resolvedAPIBaseURL() ?? "?")")
        }
    }
}

/// Shared error banner. The message is a `Text` (not a `Label`) so it can be
/// selected and copied — essential for reporting gateway/provider errors.
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

struct VisionPanelView: View {
    @ObservedObject var viewModel: ReviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let message = viewModel.errorMessage {
                errorBanner(message)
            }

            HSplitView {
                VisionPane(title: "スクリーンショット", systemImage: "rectangle.dashed") {
                    sourcePane
                }
                    .frame(minWidth: 300, idealWidth: 360)
                VisionPane(title: "読み取り結果", systemImage: "doc.text.magnifyingglass") {
                    resultPane
                }
                    .frame(minWidth: 360, idealWidth: 480)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .overlay(alignment: .bottom) {
            if viewModel.didDeploy {
                Label("クリップボードにコピーしました", systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.green.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: viewModel.didDeploy)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("画面を読む", systemImage: "eye")
                .font(.headline)
            if let ms = viewModel.lastDurationMs {
                Text("\(viewModel.lastModelName ?? "") · \(ms) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GatewayOverrideBadge()
            Spacer()
        }
        .background(WindowDragHandle())
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            previewToolbar
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.25))
                screenshotPreview
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Hand / pen tool switch, annotation tint + clear, and save.
    private var previewToolbar: some View {
        HStack(spacing: 8) {
            toolButton(.pan, icon: "hand.raised", help: "手のひらツール: ドラッグで移動、ピンチで拡大縮小、ダブルクリックで全体表示")
            toolButton(.annotate, icon: "rectangle.dashed", help: "枠線ツール: ドラッグで囲んで「この部分について」と質問できます")

            if viewModel.previewTool == .annotate {
                ForEach(ScreenshotAnnotation.Tint.allCases) { tint in
                    Button {
                        viewModel.annotationTint = tint
                    } label: {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().strokeBorder(
                                    .primary.opacity(viewModel.annotationTint == tint ? 0.8 : 0),
                                    lineWidth: 2
                                )
                                .padding(-3)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tint == .red ? "赤い枠線" : "青い枠線")
                }
            }

            if !viewModel.screenshotAnnotations.isEmpty {
                Button {
                    viewModel.screenshotAnnotations = []
                } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help("枠線をすべて消す")
            }

            Spacer()

            Button {
                viewModel.saveScreenshotAs()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.visionImage == nil)
            .help("スクリーンショットを保存")
        }
    }

    private func toolButton(_ tool: ScreenshotPreviewTool, icon: String, help: String) -> some View {
        Button {
            viewModel.previewTool = tool
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 28)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.previewTool == tool ? Color.accentColor : Color.gray.opacity(0.25))
        .foregroundStyle(viewModel.previewTool == tool ? .white : .primary)
        .help(help)
    }

    @ViewBuilder
    private var screenshotPreview: some View {
        if let attachment = viewModel.visionImage {
            ZoomableScreenshotView(
                url: attachment.url,
                tool: viewModel.previewTool,
                annotationTint: viewModel.annotationTint,
                annotations: $viewModel.screenshotAnnotations,
                highlight: viewModel.panelNavigatorHighlight
            )
            .padding(4)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("スクリーンショットがありません")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var resultPane: some View {
        if viewModel.navigatorSessionActive {
            navigatorPane
        } else if viewModel.isInterpretingVision {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("画面を読み取っています…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(EditorFocusBackground(isFocused: false))
        } else if let result = viewModel.visionResult {
            VisionInterpretationView(
                result: result,
                onApprove: { viewModel.approveSuggestedAction($0) },
                onEdit: { viewModel.editSuggestedAction($0) }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("画面の説明がここに表示されます")
                    .foregroundStyle(.tertiary)
                Button {
                    Task { await viewModel.runVisionInterpretation() }
                } label: {
                    Label("読み取る", systemImage: "eye")
                }
                .disabled(viewModel.visionImage == nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(EditorFocusBackground(isFocused: false))
        }
    }

    /// Navigator conversation: transcript on top, question input at the
    /// bottom (docs/navigator-copilot-plan.md). The auto first turn streams in
    /// while the input is already focused for the follow-up question.
    private var navigatorPane: some View {
        VStack(spacing: 10) {
            ZStack {
                // One selectable text view for the whole conversation —
                // native selection across turns, ⌘A/⌘C behave normally.
                TranscriptTextView(
                    turns: viewModel.navigatorTurns,
                    streamingText: viewModel.navigatorStreamingText.map {
                        // Markers stripped live so "[[loc:…" never flashes up.
                        NavigatorLocator.strippingMarkers($0)
                    }
                )
                if viewModel.navigatorTurns.isEmpty, viewModel.navigatorStreamingText == nil {
                    Text("この画面についてやりたいことを聞いてください")
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                if let streaming = viewModel.navigatorStreamingText,
                   NavigatorLocator.strippingMarkers(streaming).isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(viewModel.navigatorTurns.isEmpty ? "画面を見ています…" : "考えています…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(12)
                    .allowsHitTesting(false)
                }
            }
            .background(EditorFocusBackground(isFocused: false))

            // Copilot entry: the planner may have drafted an internal plan,
            // but the step count is not trustworthy enough to present as user
            // progress. Treat it as a plain guided-mode entry instead.
            if let task = viewModel.navigatorProposedTask {
                HStack(spacing: 8) {
                    Button {
                        viewModel.startProposedNavigation()
                    } label: {
                        Label(
                            "この操作を案内する: \(task.goal)",
                            systemImage: "point.bottomleft.forward.to.point.topright.scurvepath"
                        )
                        .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isNavigating)
                    .help("画面上でハイライトしながら案内を開始します")
                    Button {
                        viewModel.dismissProposedNavigation()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("提案を閉じる")
                    Spacer()
                }
            }

            // Copilot progress: show that guidance is active, but do not
            // expose the server-planned step count as if it were trustworthy
            // completion progress.
            if let task = viewModel.navigatorActiveTask {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.tint)
                    Text("案内中 · \(task.goal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }

            // Approval-driven execution (master plan stair 2): the AI
            // proposed a concrete step; nothing runs until this button.
            if let action = viewModel.navigatorProposedAction {
                HStack(spacing: 8) {
                    Button {
                        viewModel.approveNavigatorAction()
                    } label: {
                        if viewModel.isExecutingNavigatorAction {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("実行中…")
                            }
                        } else {
                            Label(action.buttonTitle, systemImage: "checkmark.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isExecutingNavigatorAction)
                    .help("承認するとこの操作を実行し、画面を撮り直して進捗を確認します")
                    Spacer()
                }
            }

            // Same dictation feedback as the compose editor: hold-to-talk is
            // one experience everywhere (mic while recording, spinner after).
            if viewModel.isRecording {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                    Text("録音中…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if viewModel.isTranscribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("文字起こし中…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                NavigatorHistoryButton()

                SendableTextEditor(
                    text: $viewModel.navigatorInput,
                    focusedField: $viewModel.focusedField,
                    field: .navigator,
                    onSend: { viewModel.sendNavigatorQuestion() },
                    onEscape: { viewModel.requestPanelClose() }
                )
                .frame(minHeight: 44, maxHeight: 88)
                .background(EditorFocusBackground(isFocused: viewModel.focusedField == .navigator))

                Button {
                    viewModel.sendNavigatorQuestion()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(!viewModel.canSendNavigatorQuestion)
                .help("質問を送る（Enter）")
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        ErrorBanner(message: message)
    }
}

private struct VisionPane<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }
}

/// "See → understand → respond": situation first, then what is being asked,
/// then prepared actions the user can approve. The raw extracted content comes
/// last as reference material.
private struct VisionInterpretationView: View {
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

/// One proposed action. These cards expose the "future reply/fill loop"
/// earlier than the rest of the screenshot UX: today's primary vision path is
/// still summary/questioning/navigation, while drafted reply/fill actions are
/// partially surfaced here for incremental rollout.
/// Approve = deploy the draft as-is into the summon-time field.
/// Edit = carry it into the compose editor.
/// Everything else is presented as guidance only — I//O never executes
/// actions itself.
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

/// A single finding card.
private struct IssueCard: View {
    let issue: ReviewIssue
    let mode: ReviewMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(categoryLabel)
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(categoryColor.opacity(0.2), in: Capsule())
                    .foregroundStyle(categoryColor)
                Text("重要度: \(issue.severity.label)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            if !issue.excerpt.isEmpty {
                Text("「\(issue.excerpt)」").font(.callout).italic()
            }
            Text(issue.explanation).font(.callout)
            if !issue.suggestion.isEmpty {
                // On the receiving side this is a note for the reader (how to read
                // it safely / what to confirm), not a fix to send back. So we drop
                // the "→" arrow (which implies an edit) and label it as a note.
                Text("\(suggestionPrefix)\(issue.suggestion)")
                    .font(.callout)
                    .foregroundStyle(.blue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    /// In transform mode the categories describe what was filtered out / what to
    /// watch for when reading, not problems the sender must fix.
    private var categoryLabel: String {
        guard mode == .transform else { return issue.category.label }
        switch issue.category {
        case .impoliteness: return "取り除いたノイズ"
        case .unclear: return "確認するとよい点"
        case .typo: return issue.category.label
        }
    }

    /// Compose mode frames the suggestion as a fix ("→ …"); transform mode frames
    /// it as a reader-facing note, so no imperative arrow.
    private var suggestionPrefix: String {
        guard mode == .transform else { return "→ " }
        switch issue.category {
        case .unclear: return "確認: "
        default: return "受け止め方: "
        }
    }

    private var categoryColor: Color {
        switch issue.category {
        case .typo: return .orange
        case .impoliteness: return .red
        case .unclear: return .purple
        }
    }
}

// MARK: - Copilot strip (docs/navigator-copilot-plan.md 正のユーザー体験)

/// The whole panel while guided navigation runs: a corner strip with the
/// current instruction and an explicit finish button. The
/// real UI is the navigated screen itself — the user clicks the highlighted
/// spot there, a global monitor notices, and the progress check runs
/// automatically.
struct CopilotStripView: View {
    @ObservedObject var viewModel: ReviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .foregroundStyle(.tint)
                if let task = viewModel.navigatorActiveTask {
                    Text("案内中")
                        .font(.caption.weight(.semibold))
                    Text(task.goal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    viewModel.requestPanelClose()
                } label: {
                    Label("終了", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("ナビゲーションを終了")
            }

            Divider()

            ScrollView {
                Text(currentInstruction)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if viewModel.isNavigating || viewModel.isCopilotChecking {
                    ProgressView().controlSize(.small)
                    Text("画面を確認しています…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "cursorarrow.click.2")
                        .foregroundStyle(.secondary)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("撮り直す") {
                    viewModel.requestCopilotProgressCheck()
                }
                .controlSize(.small)
                .disabled(viewModel.isNavigating || viewModel.isCopilotChecking)
                .help("いま手動で進捗を確認する")
            }
        }
        .padding(14)
    }

    /// The latest guidance: the streaming answer while it arrives (markers
    /// stripped live), otherwise the last finished assistant turn.
    private var currentInstruction: String {
        if let streaming = viewModel.navigatorStreamingText {
            let stripped = NavigatorLocator.strippingMarkers(streaming)
            if !stripped.isEmpty { return stripped }
        }
        if viewModel.isCopilotChecking || viewModel.isNavigating {
            return "最新の画面から次の手順を確認しています…"
        }
        return viewModel.navigatorTurns.last(where: { $0.role == .assistant })?.text
            ?? "案内を待っています…"
    }

    private var statusMessage: String {
        if viewModel.panelNavigatorHighlight != nil {
            return "赤い枠の場所をクリックしてください。クリック後、自動で進捗を確認します"
        }
        return "この案内で十分なら「終了」を押してください。必要なら「撮り直す」で再確認できます"
    }
}
