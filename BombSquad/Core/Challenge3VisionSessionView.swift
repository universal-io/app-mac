import SwiftUI

struct Challenge3VisionRootView: View {
    @ObservedObject var session: Challenge3VisionSession
    @ObservedObject private var authViewModel = AuthViewModel.shared

    var body: some View {
        Group {
            if authViewModel.hasSession {
                Challenge3VisionSessionView(session: session)
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
        return "AX \(diagnostics.candidateCount) · \(diagnostics.elapsedMs)ms · \(completion)"
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
            Text("Challenge 3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            if let metadata = session.metadata {
                Text("\(metadata.route) · \(metadata.modelID) · \(metadata.latencyMs) ms")
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
                Text(axStatus)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .help("AX候補数・取得時間・打切理由")
                Text(session.attachment.id.uuidString.prefix(8))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .help("固定capture ID")
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
                if !turn.uncertainties.isEmpty {
                    ForEach(turn.uncertainties, id: \.self) { uncertainty in
                        Label(uncertainty, systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
