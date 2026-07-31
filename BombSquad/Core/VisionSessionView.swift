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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var focusedField: Binding<FocusField?> {
        Binding(get: { session.focusedField }, set: { session.focusedField = $0 })
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
            HStack(alignment: .top, spacing: 16) {
                screenshotColumn
                    .frame(minWidth: 300, idealWidth: 420, maxWidth: .infinity)
                conversationColumn
                    .frame(minWidth: 360, idealWidth: 500, maxWidth: .infinity)
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
            Spacer()
            PanelToolInfo(
                toolName: session.activeSkillName,
                toolHelp: session.activeSkillName.map {
                    "\($0) の知識を参照して画面を読みました"
                } ?? "検出されたツールはありません",
                informationHelp: "処理情報を表示",
                informationAccessibilityLabel: "Visionの処理情報"
            ) {
                VisionDiagnosticsPopover(report: diagnosticsReport)
            }
        }
        .background(WindowDragHandle())
    }

    private var screenshotColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.25))
                ZoomableScreenshotView(
                    url: session.attachment.url,
                    tool: .pan,
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
        }
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
    }

    private var diagnosticsReport: String {
        var lines = [
            "Universal I/O Vision diagnostics",
            "",
            "[capture]",
            "id: \(session.attachment.id.uuidString.lowercased())",
            "created_at: \(Self.iso8601.string(from: session.attachment.createdAt))",
            "scope: \(session.attachment.captureScope.rawValue)",
            "pixel_size: \(optionalSize)",
            "screen_rect: \(Self.describe(session.attachment.captureRect))",
            "",
            "[skill]",
            "active: \(session.activeSkillName ?? "none")",
            "",
            "[gateway]",
        ]

        if let metadata = session.metadata {
            lines += [
                "model_vendor: \(metadata.modelVendor)",
                "model_id: \(metadata.modelID)",
                "route: \(metadata.route)",
                "api: \(metadata.api)",
                "image_detail: \(metadata.imageDetail)",
                "reasoning_effort: \(metadata.reasoningEffort)",
                "fallback_used: \(metadata.fallbackUsed)",
                "latency_ms: \(metadata.latencyMs)",
            ]
        } else {
            lines.append("status: waiting")
        }

        lines += ["", "[accessibility]"]
        if let diagnostics = session.candidateDiagnostics {
            lines += [
                "status: \(diagnostics.truncatedReason ?? "complete")",
                "elapsed_ms: \(diagnostics.elapsedMs)",
                "visited_nodes: \(diagnostics.visitedNodes)",
                "candidate_count: \(diagnostics.candidateCount)",
                "collection_root: \(diagnostics.collectionRoot)",
                "capture_scope: \(diagnostics.captureScope)",
                "collection_passes: \(diagnostics.collectionPasses)",
                "web_area_present: \(diagnostics.webAreaPresent)",
                "target_app: \(diagnostics.targetAppName ?? "none")",
                "target_bundle_id: \(diagnostics.targetBundleID ?? "none")",
                "target_window: \(diagnostics.targetWindowTitle ?? "none")",
            ]
        } else {
            lines.append("status: collecting")
        }

        lines += ["", "[selected_candidate]"]
        if let candidate = session.selectedCandidate {
            lines += [
                "id: \(candidate.id)",
                "source: \(candidate.source)",
                "role: \(candidate.role ?? "none")",
                "label: \(candidate.label)",
                "parent_label: \(candidate.parentLabel ?? "none")",
                "states: \(candidate.states.isEmpty ? "none" : candidate.states.joined(separator: ", "))",
                "rect: \(Self.describe(candidate.rect))",
            ]
        } else {
            lines.append("status: none")
        }

        return lines.joined(separator: "\n")
    }

    private var optionalSize: String {
        guard let width = session.attachment.pixelWidth,
              let height = session.attachment.pixelHeight else {
            return "unknown"
        }
        return "\(width)x\(height)"
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return String(
            format: "x=%.4f y=%.4f width=%.4f height=%.4f",
            rect.minX, rect.minY, rect.width, rect.height
        )
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

private struct VisionDiagnosticsPopover: View {
    let report: String

    var body: some View {
        PanelInformationPopover(
            title: "Visionの処理情報",
            copyText: report,
            note:
                "開発とトラブルシューティング用です。画像・入力本文・回答本文は含みませんが、"
                    + "ウィンドウ名や選択候補ラベルを含む場合があります。"
        ) {
            ScrollView([.vertical, .horizontal]) {
                Text(report)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 480, height: 360)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
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
