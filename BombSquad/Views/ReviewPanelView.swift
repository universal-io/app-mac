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
                if let ms = viewModel.lastDurationMs {
                    Text("\(viewModel.lastModelName ?? "") · \(ms) ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let message = viewModel.errorMessage {
                errorBanner(message)
            }

            if let result = viewModel.result {
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
                Label(viewModel.mode == .transform ? "クリップボードにコピーしました" : "送信先へ入力しました",
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
            onSend: { viewModel.deployRevision() }
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
                Label(viewModel.mode == .transform ? "コピー" : "送信",
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
        Label(message, systemImage: "exclamationmark.triangle.fill")
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
            Spacer()
            Button {
                NotificationCenter.default.post(name: .captureScreenshot, object: nil)
            } label: {
                Label("撮り直す", systemImage: "camera.viewfinder")
            }
            .disabled(viewModel.isCapturingScreenshot)
            .help("画面全体を自動で撮り直します")

            Button {
                NotificationCenter.default.post(
                    name: .captureScreenshot, object: nil, userInfo: ["interactive": true]
                )
            } label: {
                Label("範囲を選ぶ", systemImage: "rectangle.dashed")
            }
            .disabled(viewModel.isCapturingScreenshot)
            .help("読み取る範囲をドラッグで選択します")

            Button {
                Task { await viewModel.runVisionInterpretation() }
            } label: {
                Label("再読み取り", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(viewModel.visionImage == nil || viewModel.isInterpretingVision)

            Button {
                viewModel.copyVisionResult()
            } label: {
                Label("コピー", systemImage: "doc.on.clipboard.fill")
            }
            .disabled(viewModel.visionResult == nil)
        }
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.25))
                screenshotPreview
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let attachment = viewModel.visionImage {
                HStack(spacing: 8) {
                    Text(attachment.fileName)
                        .font(.caption)
                        .lineLimit(1)
                    if let sizeLabel = attachment.sizeLabel {
                        Text(sizeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var screenshotPreview: some View {
        if let attachment = viewModel.visionImage,
           let image = NSImage(contentsOf: attachment.url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(12)
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
        if viewModel.isInterpretingVision {
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

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.red)
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
                    Button {
                        onEdit()
                    } label: {
                        Label("編集する", systemImage: "square.and.pencil")
                    }
                    .help("文案を原文エディタに引き継いで編集します")

                    Button {
                        onApprove()
                    } label: {
                        Label(action.kind == .reply ? "承認して送信" : "承認して入力",
                              systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("この文案をそのまま呼び出し元のフィールドへ入力します")
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
