import SwiftUI

/// Thin Phase 3-b surface: selected text on the left, interpreted result on
/// the right, with a clipboard-only exit.
struct FoundationTransformRootView: View {
    @ObservedObject var session: TransformSession
    @ObservedObject private var authViewModel = AuthViewModel.shared

    var body: some View {
        Group {
            if authViewModel.hasSession {
                TransformSessionView(session: session)
                    .task { session.startInitialInterpretationIfNeeded() }
            } else {
                LoginRequiredView(
                    viewModel: authViewModel,
                    config: BombSquadConfig.snapshot()
                )
            }
        }
        .panelChrome()
        .onChange(of: authViewModel.hasSession) { _, hasSession in
            guard hasSession else { return }
            session.startInitialInterpretationIfNeeded()
        }
    }
}

struct TransformSessionView: View {
    @ObservedObject var session: TransformSession

    var body: some View {
        VStack(spacing: 0) {
            sourcePane
            resultPane
        }
        .frame(minWidth: 620, minHeight: 640)
        .overlay(alignment: .bottom) {
            if session.didCopy {
                Label("クリップボードにコピーしました", systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: session.didCopy)
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let context = session.situationalContext, !session.isContextExcluded {
                FoundationContextChip(context: context, onExclude: session.excludeContext)
            }

            ScrollView {
                Text(session.draft)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(EditorFocusBackground(isFocused: false))

            HStack {
                Spacer()
                if session.isInterpreting {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        session.requestInterpretation()
                    } label: {
                        Label("もう一度整理", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .padding()
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("読み取り結果", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                FoundationManagementMenu()
                if session.result != nil {
                    Button(action: session.copyInterpretation) {
                        Label("コピー", systemImage: "doc.on.clipboard.fill")
                    }
                    .help("整理した内容全体をクリップボードにコピーします")
                }
                if let ms = session.lastDurationMs {
                    Text("\(session.lastModelName ?? "") · \(ms) ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                GatewayOverrideBadge()
            }
            .background(WindowDragHandle())

            if let error = session.errorMessage {
                ErrorBanner(message: error)
            }

            if let result = session.result {
                VisionInterpretationView(
                    result: result,
                    isTransform: true,
                    onApprove: session.approveSuggestedAction,
                    onEdit: { _ in }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.isInterpreting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("読みやすく整理しています…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
                .background(EditorFocusBackground(isFocused: false))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("選択したテキストの整理結果がここに表示されます")
                        .foregroundStyle(.tertiary)
                    Button {
                        session.requestInterpretation()
                    } label: {
                        Label("整理する", systemImage: "wand.and.stars")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
                .background(EditorFocusBackground(isFocused: false))
            }
        }
        .padding()
    }
}
