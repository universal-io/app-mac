import AppKit
import SwiftUI

/// Thin Phase 3-c/d screenshot interpretation surface. One-shot Vision stays
/// intact; the first question escalates into Navigator, and Copilot reuses
/// the same session as a corner strip.
struct FoundationVisionRootView: View {
    @ObservedObject var session: VisionSession
    let mode: AppMode
    @ObservedObject private var authViewModel = AuthViewModel.shared

    var body: some View {
        Group {
            if authViewModel.hasSession {
                switch mode {
                case .copilot:
                    CoreCopilotStripView(session: session)
                default:
                    VisionSessionView(session: session)
                }
            } else {
                LoginRequiredView(
                    viewModel: authViewModel,
                    config: BombSquadConfig.snapshot()
                )
            }
        }
        .panelChrome()
        .task {
            session.startInitialFlowIfNeeded()
        }
    }
}

struct VisionSessionView: View {
    @ObservedObject var session: VisionSession
    @ObservedObject private var noticeCenter = OperationalNoticeCenter.shared
    @State private var annotations: [ScreenshotAnnotation] = []
    @State private var previewTool: ScreenshotPreviewTool = .pan
    @State private var annotationTint: ScreenshotAnnotation.Tint = .red

    private var focusedField: Binding<FocusField?> {
        Binding(get: { session.focusedField }, set: { session.focusedField = $0 })
    }

    private var showsNavigatorPane: Bool {
        session.hasNavigatorConversation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = session.errorMessage {
                ErrorBanner(message: error)
            }
            if let notice = noticeCenter.current {
                OperationalNoticeBanner(
                    message: notice.message,
                    onDismiss: noticeCenter.dismiss
                )
            }

            HSplitView {
                VisionColumn(title: "スクリーンショット", systemImage: "rectangle.dashed") {
                    sourcePane
                }
                .frame(minWidth: 300, idealWidth: 360)

                VisionColumn(title: "読み取り結果", systemImage: "doc.text.magnifyingglass") {
                    resultPane
                }
                .frame(minWidth: 360, idealWidth: 480)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .onAppear {
            if session.isNavigatorAvailable {
                DispatchQueue.main.async {
                    session.focusedField = .navigator
                }
            }
        }
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
            FoundationManagementMenu()
        }
        .background(WindowDragHandle())
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let context = session.situationalContext, !session.isContextExcluded {
                FoundationContextChip(context: context, onExclude: session.excludeContext)
            }

            previewToolbar

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.25))
                ZoomableScreenshotView(
                    url: session.attachment.url,
                    tool: previewTool,
                    annotationTint: annotationTint,
                    annotations: $annotations,
                    highlight: session.panelNavigatorHighlight
                )
                .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var previewToolbar: some View {
        HStack(spacing: 8) {
            previewToolButton(
                .pan,
                icon: "hand.raised",
                help: "手のひらツール: ドラッグで移動、ピンチで拡大縮小、ダブルクリックで全体表示"
            )
            previewToolButton(
                .annotate,
                icon: "rectangle.dashed",
                help: "枠線ツール: ドラッグで画面の一部を囲みます"
            )

            if previewTool == .annotate {
                ForEach(ScreenshotAnnotation.Tint.allCases) { tint in
                    Button {
                        annotationTint = tint
                    } label: {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().strokeBorder(
                                    .primary.opacity(annotationTint == tint ? 0.8 : 0),
                                    lineWidth: 2
                                )
                                .padding(-3)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tint == .red ? "赤い枠線" : "青い枠線")
                    .accessibilityLabel(tint == .red ? "赤い枠線" : "青い枠線")
                }
            }

            if !annotations.isEmpty {
                Button {
                    annotations = []
                } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help("枠線をすべて消す")
                .accessibilityLabel("枠線をすべて消す")
            }

            Spacer()

            Button(action: session.saveScreenshotAs) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help("スクリーンショットを保存")
            .accessibilityLabel("スクリーンショットを保存")
        }
    }

    private func previewToolButton(
        _ tool: ScreenshotPreviewTool,
        icon: String,
        help: String
    ) -> some View {
        Button {
            previewTool = tool
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 28)
        }
        .buttonStyle(.borderless)
        .background(previewTool == tool ? Color.accentColor.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var resultPane: some View {
        if showsNavigatorPane {
            VStack(spacing: 10) {
                if let result = session.result {
                    VisionInterpretationView(
                        result: result,
                        onApprove: session.approveSuggestedAction,
                        onEdit: session.editSuggestedAction
                    )
                    .frame(minHeight: 160, maxHeight: 260)
                } else if session.isInterpreting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("画面を読み取っています…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(EditorFocusBackground(isFocused: false))
                }

                navigatorPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.isInterpreting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("画面を読み取っています…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(EditorFocusBackground(isFocused: false))
        } else if let result = session.result {
            VStack(spacing: 10) {
                VisionInterpretationView(
                    result: result,
                    onApprove: session.approveSuggestedAction,
                    onEdit: session.editSuggestedAction
                )
                if session.isNavigatorAvailable {
                    navigatorComposer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("画面の説明がここに表示されます")
                    .foregroundStyle(.tertiary)
                Button {
                    session.requestInterpretation()
                } label: {
                    Label("読み取る", systemImage: "eye")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(EditorFocusBackground(isFocused: false))
        }
    }

    private var navigatorComposer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                CoreNavigatorHistoryButton()

                SendableTextEditor(
                    text: $session.navigatorInput,
                    focusedField: focusedField,
                    field: .navigator,
                    onSend: session.sendNavigatorQuestion,
                    onEscape: session.requestPanelClose
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

    private var navigatorPane: some View {
        VStack(spacing: 10) {
            ZStack {
                CoreTranscriptTextView(
                    turns: session.navigatorTurns,
                    streamingText: session.navigatorStreamingText.map {
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

            if let task = session.navigatorProposedTask {
                HStack(spacing: 8) {
                    Button {
                        session.startProposedNavigation()
                    } label: {
                        Label(
                            "この操作を案内する: \(task.goal)",
                            systemImage: "point.bottomleft.forward.to.point.topright.scurvepath"
                        )
                        .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isNavigating)
                    Button {
                        session.dismissProposedNavigation()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }

            if let task = session.navigatorActiveTask {
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
                    Spacer()
                }
            }

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
                CoreNavigatorHistoryButton()

                SendableTextEditor(
                    text: $session.navigatorInput,
                    focusedField: focusedField,
                    field: .navigator,
                    onSend: session.sendNavigatorQuestion,
                    onEscape: session.requestPanelClose
                )
                .frame(minHeight: 44, maxHeight: 88)
                .background(EditorFocusBackground(isFocused: session.focusedField == .navigator))

                Button {
                    session.sendNavigatorQuestion()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(!session.canSendNavigatorQuestion)
            }
        }
    }
}

private struct CoreCopilotStripView: View {
    @ObservedObject var session: VisionSession
    @ObservedObject private var noticeCenter = OperationalNoticeCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = noticeCenter.current {
                OperationalNoticeBanner(
                    message: notice.message,
                    onDismiss: noticeCenter.dismiss
                )
            }
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .foregroundStyle(.tint)
                if let task = session.navigatorActiveTask {
                    Text("案内中")
                        .font(.caption.weight(.semibold))
                    Text(task.goal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                FoundationManagementMenu()
                Button {
                    session.requestPanelClose()
                } label: {
                    Label("終了", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            ScrollView {
                Text(currentInstruction)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if session.isNavigating || session.isCopilotChecking {
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
                    session.requestCopilotProgressCheck()
                }
                .controlSize(.small)
                .disabled(session.isNavigating || session.isCopilotChecking)
            }
        }
        .padding(14)
    }

    private var currentInstruction: String {
        if let streaming = session.navigatorStreamingText {
            let stripped = NavigatorLocator.strippingMarkers(streaming)
            if !stripped.isEmpty { return stripped }
        }
        if session.isCopilotChecking || session.isNavigating {
            switch session.copilotCaptureState {
            case .waitingForChange:
                return "クリック後の画面変化を待っています…"
            case .settling:
                return "画面が切り替わり中です。安定するまで待っています…"
            default:
                return "最新の画面から次の手順を確認しています…"
            }
        }
        if session.copilotCaptureState == .timedOut {
            return "画面遷移の完了を確認できませんでした。反映後に「撮り直す」で再確認してください。"
        }
        return session.navigatorTurns.last(where: { $0.role == .assistant })?.text ?? "案内を待っています…"
    }

    private var statusMessage: String {
        if session.copilotCaptureState == .timedOut {
            return "画面変化が安定しなかったため自動確認を止めました。「撮り直す」で再確認してください"
        }
        if session.panelNavigatorHighlight != nil {
            return "赤い枠の場所をクリックしてください。クリック後、自動で進捗を確認します"
        }
        return "この案内で十分なら「終了」を押してください。必要なら「撮り直す」で再確認できます"
    }
}

private struct VisionColumn<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

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

private struct CoreNavigatorHistoryButton: View {
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
                CoreTranscriptTextView(
                    turns: selected.turns.map {
                        CoreNavigatorDisplayTurn(
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

private struct CoreTranscriptTextView: NSViewRepresentable {
    let turns: [CoreNavigatorDisplayTurn]
    let streamingText: String?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [:]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let content = Self.attributedTranscript(turns: turns, streaming: streamingText)
        guard textView.textStorage?.string != content.string else { return }
        textView.textStorage?.setAttributedString(content)
        textView.scrollToEndOfDocument(nil)
    }

    private static func attributedTranscript(
        turns: [CoreNavigatorDisplayTurn],
        streaming: String?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let userParagraph = NSMutableParagraphStyle()
        userParagraph.paragraphSpacing = 4
        let userAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: userParagraph,
        ]

        let assistantParagraph = NSMutableParagraphStyle()
        assistantParagraph.paragraphSpacing = 14
        assistantParagraph.lineSpacing = 2
        let assistantAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: assistantParagraph,
        ]

        func append(role: NavigateTurn.Role, text: String) {
            guard !text.isEmpty else { return }
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            switch role {
            case .user:
                result.append(NSAttributedString(string: "▸ \(text)", attributes: userAttributes))
            case .assistant:
                result.append(NSAttributedString(string: text, attributes: assistantAttributes))
            }
        }

        for turn in turns {
            append(role: turn.role, text: turn.text)
        }
        if let streaming, !streaming.isEmpty {
            append(role: .assistant, text: streaming)
        }
        return result
    }
}
