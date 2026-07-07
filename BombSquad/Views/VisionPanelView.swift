import AppKit
import SwiftUI

/// Screen Q&A panel (AppMode.navigator): screenshot on the left, the
/// navigator conversation (or the one-shot interpretation fallback) on the
/// right.
struct VisionPanelView: View {
    @ObservedObject var session: NavigatorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let message = session.errorMessage {
                ErrorBanner(message: message)
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
            if session.didDeploy {
                Label("クリップボードにコピーしました", systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.green.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: session.didDeploy)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("画面を読む", systemImage: "eye")
                .font(.headline)
            if let ms = session.lastDurationMs {
                Text("\(session.lastModelName ?? "") · \(ms) ms")
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

            if session.previewTool == .annotate {
                ForEach(ScreenshotAnnotation.Tint.allCases) { tint in
                    Button {
                        session.annotationTint = tint
                    } label: {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().strokeBorder(
                                    .primary.opacity(session.annotationTint == tint ? 0.8 : 0),
                                    lineWidth: 2
                                )
                                .padding(-3)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tint == .red ? "赤い枠線" : "青い枠線")
                }
            }

            if !session.screenshotAnnotations.isEmpty {
                Button {
                    session.screenshotAnnotations = []
                } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help("枠線をすべて消す")
            }

            Spacer()

            Button {
                session.saveScreenshotAs()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .disabled(session.visionImage == nil)
            .help("スクリーンショットを保存")
        }
    }

    private func toolButton(_ tool: ScreenshotPreviewTool, icon: String, help: String) -> some View {
        Button {
            session.previewTool = tool
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 28)
        }
        .buttonStyle(.borderedProminent)
        .tint(session.previewTool == tool ? Color.accentColor : Color.gray.opacity(0.25))
        .foregroundStyle(session.previewTool == tool ? .white : .primary)
        .help(help)
    }

    @ViewBuilder
    private var screenshotPreview: some View {
        if let attachment = session.visionImage {
            ZoomableScreenshotView(
                url: attachment.url,
                tool: session.previewTool,
                annotationTint: session.annotationTint,
                annotations: $session.screenshotAnnotations,
                highlight: session.navigatorHighlight
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
        if session.navigatorSessionActive {
            navigatorPane
        } else if session.isInterpretingVision {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("画面を読み取っています…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(EditorFocusBackground(isFocused: false))
        } else if let result = session.visionResult {
            VisionInterpretationView(
                result: result,
                onApprove: { session.approveSuggestedAction($0) },
                onEdit: { session.editSuggestedAction($0) }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("画面の説明がここに表示されます")
                    .foregroundStyle(.tertiary)
                Button {
                    Task { await session.runVisionInterpretation() }
                } label: {
                    Label("読み取る", systemImage: "eye")
                }
                .disabled(session.visionImage == nil)
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
                    turns: session.navigatorTurns,
                    streamingText: session.navigatorStreamingText.map {
                        // Markers stripped live so "[[loc:…" never flashes up.
                        NavigatorLocator.strippingMarkers($0)
                    }
                )
                if session.navigatorTurns.isEmpty, session.navigatorStreamingText == nil {
                    Text("この画面についてやりたいことを聞いてください")
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                if let streaming = session.navigatorStreamingText,
                   NavigatorLocator.strippingMarkers(streaming).isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(session.navigatorTurns.isEmpty ? "画面を見ています…" : "考えています…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(12)
                    .allowsHitTesting(false)
                }
            }
            .background(EditorFocusBackground(isFocused: false))

            // Copilot entry (docs/navigator-copilot-plan.md §3-c): the
            // planner proposed a step plan; guided mode starts only on this
            // tap — a deterministic mode switch, not a model judgement.
            if let task = session.navigatorProposedTask {
                HStack(spacing: 8) {
                    Button {
                        session.startProposedNavigation()
                    } label: {
                        Label(
                            "ナビゲーション開始（\(task.steps.count)ステップ）: \(task.goal)",
                            systemImage: "point.bottomleft.forward.to.point.topright.scurvepath"
                        )
                        .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isNavigating)
                    .help("ステップごとに画面上でハイライトしながら案内します")
                    Button {
                        session.dismissProposedNavigation()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("提案を閉じる")
                    Spacer()
                }
            }

            // Copilot progress: plan and step cursor are session data, shown
            // so the user always knows where the guidance stands.
            if let task = session.navigatorActiveTask {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.tint)
                    Text("ステップ \(min(task.currentStep + 1, task.steps.count))/\(task.steps.count) · \(task.goal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }

            // Approval-driven execution (master plan stair 2): the AI
            // proposed a concrete step; nothing runs until this button.
            if let action = session.navigatorProposedAction {
                HStack(spacing: 8) {
                    Button {
                        session.approveNavigatorAction()
                    } label: {
                        if session.isExecutingNavigatorAction {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("実行中…")
                            }
                        } else {
                            Label(action.buttonTitle, systemImage: "checkmark.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isExecutingNavigatorAction)
                    .help("承認するとこの操作を実行し、画面を撮り直して進捗を確認します")
                    Spacer()
                }
            }

            // Same dictation feedback as the compose editor: hold-to-talk is
            // one experience everywhere (mic while recording, spinner after).
            if session.isRecording {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                    Text("録音中…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if session.isTranscribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("文字起こし中…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                NavigatorHistoryButton()

                SendableTextEditor(
                    text: $session.navigatorInput,
                    focusedField: $session.focusedField,
                    field: .navigator,
                    onSend: { session.sendNavigatorQuestion() },
                    onEscape: { session.requestExitToCompose() }
                )
                .frame(minHeight: 44, maxHeight: 88)
                .background(EditorFocusBackground(isFocused: session.focusedField == .navigator))

                Button {
                    session.sendNavigatorQuestion()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(!session.canSendNavigatorQuestion)
                .help("質問を送る（Enter）")
            }
        }
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

// MARK: - Copilot strip (docs/navigator-copilot-plan.md 正のユーザー体験)

/// The whole panel while guided navigation runs: a corner strip with the
/// step counter, the current instruction, and an exit button. The real UI is
/// the navigated screen itself — the user clicks the highlighted spot there,
/// a global monitor notices, and the progress check runs automatically.
struct CopilotStripView: View {
    @ObservedObject var session: CopilotSession
    /// The wrapped conversation: step cursor, streaming text, and turns all
    /// live there, so the strip observes it directly.
    @ObservedObject var navigator: NavigatorSession
    /// The strip's exit button ends the whole session (F6 in golden paths).
    let onExit: () -> Void

    @MainActor
    init(session: CopilotSession, onExit: @escaping () -> Void) {
        self.session = session
        self.navigator = session.navigator
        self.onExit = onExit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .foregroundStyle(.tint)
                if let task = navigator.navigatorActiveTask {
                    Text("ステップ \(min(task.currentStep + 1, task.steps.count))/\(task.steps.count)")
                        .font(.caption.weight(.semibold))
                    Text(task.goal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    onExit()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
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
                if navigator.isNavigating || session.isChecking {
                    ProgressView().controlSize(.small)
                    Text("画面を確認しています…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "cursorarrow.click.2")
                        .foregroundStyle(.secondary)
                    Text("赤い枠の場所をクリックしてください。クリック後、自動で進捗を確認します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("撮り直す") {
                    session.requestProgressCheck()
                }
                .controlSize(.small)
                .disabled(navigator.isNavigating || session.isChecking)
                .help("いま手動で進捗を確認する")
            }
        }
        .padding(14)
    }

    /// The latest guidance: the streaming answer while it arrives (markers
    /// stripped live), otherwise the last finished assistant turn.
    private var currentInstruction: String {
        if let streaming = navigator.navigatorStreamingText {
            let stripped = NavigatorLocator.strippingMarkers(streaming)
            if !stripped.isEmpty { return stripped }
        }
        return navigator.navigatorTurns.last(where: { $0.role == .assistant })?.text
            ?? "案内を待っています…"
    }
}
