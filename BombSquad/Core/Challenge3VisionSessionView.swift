import SwiftUI

struct Challenge3VisionRootView: View {
    @ObservedObject var session: Challenge3VisionSession
    @ObservedObject private var authViewModel = AuthViewModel.shared

    var body: some View {
        Group {
            if authViewModel.hasSession {
                if session.isCopilotActive {
                    Challenge3CopilotStripView(session: session)
                } else {
                    Challenge3VisionSessionView(session: session)
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

struct Challenge3VisionSessionView: View {
    @ObservedObject var session: Challenge3VisionSession
    @State private var annotations: [ScreenshotAnnotation] = []
    @State private var previewTool: ScreenshotPreviewTool = .pan

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
            Text("Challenge 3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            if let metadata = session.metadata {
                Text("\(metadata.route) · \(metadata.modelID) · \(metadata.latencyMs) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
#endif
            GatewayOverrideBadge()
            Spacer()
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
                    highlight: session.screenshotHighlight
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
            Label("読み取り結果", systemImage: "doc.text.magnifyingglass")
                .font(.headline)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(session.turns) { turn in
                            turnView(turn)
                                .id(turn.id)
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
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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

                Button(action: session.sendQuestion) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(!session.canSend)
                .help("質問を送る（Enter）")
                .accessibilityLabel("質問を送る")
            }
            if session.canStartCopilot {
                Button {
                    session.startCopilot()
                } label: {
                    Label("案内を開始", systemImage: "location.fill")
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func turnView(_ turn: Challenge3VisionDisplayTurn) -> some View {
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

private struct Challenge3CopilotStripView: View {
    @ObservedObject var session: Challenge3VisionSession

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
