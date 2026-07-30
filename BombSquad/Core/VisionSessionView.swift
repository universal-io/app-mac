import SwiftUI

struct VisionRootView: View {
    @ObservedObject var session: VisionSession
    @ObservedObject private var authViewModel = AuthViewModel.shared
    @ObservedObject private var noticeCenter = OperationalNoticeCenter.shared

    var body: some View {
        Group {
            if authViewModel.hasSession {
                VStack(spacing: 0) {
                    if let notice = noticeCenter.current {
                        OperationalNoticeBanner(
                            message: notice.message,
                            onDismiss: noticeCenter.dismiss
                        )
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                    }
                    if session.isCopilotActive {
                        CopilotStripView(session: session)
                    } else {
                        VisionSessionView(session: session)
                    }
                }
            } else {
                LoginRequiredView(
                    viewModel: authViewModel,
                    config: BombSquadConfig.snapshot()
                )
            }
        }
        .panelChrome()
        .task { session.startIfNeeded() }
    }
}

struct VisionSessionView: View {
    @ObservedObject var session: VisionSession
    @State private var annotations: [ScreenshotAnnotation] = []
    @State private var previewTool: ScreenshotPreviewTool = .pan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var focusedField: Binding<FocusField?> {
        Binding(get: { session.focusedField }, set: { session.focusedField = $0 })
    }

    private var axStatus: String {
        guard let diagnostics = session.candidateDiagnostics else {
            return session.candidatesReady ? "AX \(session.candidates.count)" : "AX …"
        }
        let completion = diagnostics.truncatedReason ?? "complete"
        return "AX \(diagnostics.candidateCount) · \(diagnostics.elapsedMs)ms · \(diagnostics.collectionRoot) · \(completion)"
    }

    private var axStatusHelp: String {
        guard let diagnostics = session.candidateDiagnostics else {
            return "AX候補を取得しています"
        }
        let app = diagnostics.targetAppName ?? "対象アプリなし"
        let window = diagnostics.targetWindowTitle ?? "focused windowなし"
        return "収集対象: \(app) / \(window)\nAX root: \(diagnostics.collectionRoot)\nCapture: \(diagnostics.captureScope)\nPasses: \(diagnostics.collectionPasses) / WebArea: \(diagnostics.webAreaPresent ? "あり" : "なし")"
    }

    private var focusTargetHighlight: CGRect? {
        session.focusTarget?.normalizedFrame(in: session.attachment)
    }

    private var previewHighlight: CGRect? {
        session.screenshotHighlight ?? focusTargetHighlight
    }

    private var isShowingFocusTargetHighlight: Bool {
        session.screenshotHighlight == nil && focusTargetHighlight != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let errorMessage = session.errorMessage {
                ErrorBanner(message: errorMessage)
            }
            HSplitView {
                screenshotColumn
                    .frame(minWidth: 300, idealWidth: 420)
                conversationColumn
                    .frame(minWidth: 360, idealWidth: 500)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .onAppear { session.focusedField = .navigator }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("画面を読む", systemImage: "eye")
                .font(.headline)
#if DEBUG
            if let metadata = session.metadata {
                Text("\(metadata.route) · \(metadata.modelID) · \(metadata.latencyMs) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
#endif
            Spacer()
            if let skillName = session.activeSkillName {
                ActiveSkillLabel(
                    skillName: skillName,
                    help: "\(skillName) の知識を参照して画面を読みました"
                )
            }
        }
        .background(WindowDragHandle())
    }

    private var screenshotColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("スクリーンショット", systemImage: "rectangle.dashed")
                .font(.headline)
            HStack {
                Button {
                    previewTool = .pan
                } label: {
                    Image(systemName: "hand.raised")
                        .frame(width: 30, height: 24)
                }
                .buttonStyle(.borderless)
                .help("画像を移動・拡大する")
                .accessibilityLabel("画像を移動・拡大する")
                Spacer()
#if DEBUG
                Text(axStatus)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .help(axStatusHelp)
                Text(session.attachment.id.uuidString.prefix(8))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .help("固定capture ID")
#endif
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.25))
                ZoomableScreenshotView(
                    url: session.attachment.url,
                    tool: previewTool,
                    annotationTint: .red,
                    annotations: $annotations,
                    highlight: previewHighlight,
                    highlightTint: isShowingFocusTargetHighlight ? .accentColor : .red,
                    highlightLabel: isShowingFocusTargetHighlight ? "選択対象" : "次の操作"
                )
                .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#if DEBUG
            if let candidate = session.selectedCandidate {
                Label(
                    "\(session.metadata?.route ?? "unknown") · \(candidate.id) · \(candidate.label)",
                    systemImage: "scope"
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("選択経路・candidate ID・AXラベル")
            }
#endif
        }
        .padding()
    }

    private var conversationColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let focusTarget = session.focusTarget {
                VisionFocusTargetCard(
                    target: focusTarget,
                    locationAvailable: focusTargetHighlight != nil
                )
                .accessibilitySortPriority(4)
            }

            Label("読み取り結果", systemImage: "doc.text.magnifyingglass")
                .font(.headline)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(session.turns) { turn in
                            turnView(turn)
                                .id(turn.id)
                                .accessibilitySortPriority(3)
                        }
                        if session.isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(session.turns.isEmpty ? "画面を見ています…" : "考えています…")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }
                .background(EditorFocusBackground(isFocused: false))
                .onChange(of: session.turns.count) {
                    guard let last = session.turns.last else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                SendableTextEditor(
                    text: $session.input,
                    focusedField: focusedField,
                    field: .navigator,
                    onSend: session.sendQuestion,
                    onEscape: session.requestPanelClose
                )
                .frame(minHeight: 52, maxHeight: 96)
                .background(EditorFocusBackground(isFocused: session.focusedField == .navigator))

                PanelSendButton(
                    accessibilityLabel: "Visionへの質問を送信",
                    help: "質問を送信（Enter）",
                    isEnabled: session.canSend,
                    action: session.sendQuestion
                )
            }
            .accessibilitySortPriority(2)
            if session.canStartCopilot {
                Button {
                    session.startCopilot()
                } label: {
                    Label("案内を開始", systemImage: "location.fill")
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("選択対象について案内を開始")
                .accessibilityHint("同じ会話の内容を引き継いで操作案内を開始します")
                .accessibilitySortPriority(1)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func turnView(_ turn: VisionDisplayTurn) -> some View {
        if turn.role == .user {
            Text("▸ \(turn.text)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(turn.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
#if DEBUG
                if !turn.uncertainties.isEmpty {
                    ForEach(turn.uncertainties, id: \.self) { uncertainty in
                        Label(uncertainty, systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
#endif
            }
        }
    }
}

private struct VisionFocusTargetCard: View {
    let target: VisionFocusTarget
    let locationAvailable: Bool

    @State private var isExpanded = false
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var isLongText: Bool {
        guard let text = target.text else { return false }
        return text.count > 280 || text.filter(\.isNewline).count > 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(target.displayTitle, systemImage: "scope")
                .font(.headline)
                .foregroundStyle(.primary)

            if let label = target.label, !label.isEmpty {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let text = target.text, !text.isEmpty {
                Group {
                    if isExpanded {
                        ScrollView {
                            targetText(text)
                        }
                        .frame(maxHeight: 160)
                    } else {
                        targetText(text)
                            .lineLimit(4)
                    }
                }

                if isLongText {
                    Button(isExpanded ? "折りたたむ" : "全文を表示") {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.link)
                    .accessibilityHint(
                        isExpanded
                            ? "選択テキストを短く表示します"
                            : "選択テキスト全文をスクロール可能な領域に表示します"
                    )
                }
            }

            Divider()

            Label("取得元: \(target.sourceDescription)", systemImage: "arrow.down.to.line")
                .font(.caption)
                .foregroundStyle(.secondary)

            Label(
                locationAvailable
                    ? "スクリーンショット上の位置を表示中"
                    : "スクリーンショット上の位置は取得できませんでした",
                systemImage: locationAvailable ? "viewfinder" : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    Color.accentColor,
                    lineWidth: colorSchemeContrast == .increased ? 2 : 1
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("現在の選択対象")
    }

    private func targetText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CopilotStripView: View {
    @ObservedObject var session: VisionSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .foregroundStyle(.tint)
                Text("案内中")
                    .font(.caption.weight(.semibold))
                Text(session.copilotGoal ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let skillName = session.activeSkillName {
                    ActiveSkillLabel(
                        skillName: skillName,
                        help: "\(skillName) の知識を参照して案内しています"
                    )
                }
                Button {
                    session.stopCopilot()
                } label: {
                    Label("終了", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            if let errorMessage = session.errorMessage {
                ErrorBanner(message: errorMessage)
            }

            Text(session.latestInstruction)
                .font(.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .textSelection(.enabled)

            if session.copilotSawNoChange {
                Label(
                    "操作は検知しましたが、画面に変化は見えませんでした",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                if session.isCopilotChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusIcon)
                        .foregroundStyle(.secondary)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.copilotState != .complete, session.copilotState != .stepLimit {
                    Button {
                        session.requestCopilotProgressCheck()
                    } label: {
                        Label("再確認", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(session.isCopilotChecking)
                }
            }
        }
        .padding(14)
        .background(WindowDragHandle())
    }

    private var statusText: String {
        switch session.copilotState {
        case .idle:
            // A guide turn may legitimately return no target (candidate
            // missing from AX); never point the user at a red frame that
            // does not exist.
            return session.selectedCandidate != nil
                ? "赤い枠の場所をクリックしてください。画面変化を自動で確認します"
                : "案内に従って操作してください。操作後の画面を自動で確認します"
        case .waitingForChange:
            return "クリック後の画面変化と安定を待っています…"
        case .evaluating:
            return "新しい画面から次の案内を確認しています…"
        case .timedOut:
            return "画面を撮影できませんでした。「再確認」を押してください"
        case .complete:
            return "目的の情報を確認しました"
        case .clarification:
            return "案内をご確認ください。進める場合はそのまま操作すると続きます"
        case .stepLimit:
            return "案内の回数が上限に達しました。目的を絞ってもう一度質問してください"
        }
    }

    private var statusIcon: String {
        switch session.copilotState {
        case .complete:
            return "checkmark.circle.fill"
        case .timedOut, .clarification, .stepLimit:
            return "exclamationmark.circle"
        default:
            return "cursorarrow.click.2"
        }
    }
}
