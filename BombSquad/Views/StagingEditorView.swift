import SwiftUI

/// Left pane: the staging area where the user drafts/pastes the message
/// before it is reviewed. Nothing here is "live" yet.
struct StagingEditorView: View {
    let session: PanelSession
    @ObservedObject var viewModel: ReviewViewModel
    /// Shared focus across both editors (drives the blue highlight).
    @Binding var focusedField: FocusField?
    /// Drives the help popover anchored to the (?) button.
    @State private var showHelp = false

    /// The blue focus ring appears only once there are two candidates
    /// (original vs revision) and it answers "which side will Enter send?".
    /// A lone draft editor with a ring is visual noise (owner call, 2026-07-03).
    private var isFocused: Bool { focusedField == .draft && viewModel.canFocusRevision }

    /// Hotkeys shown in the help popover. Kept terse: keys only.
    private let shortcuts: [(String, String)] = [
        ("Enter", "確定"),
        ("Shift+Enter", "改行"),
        ("右Shift ×2", "起動 / レビュー / 画面"),
        ("右Shift 長押し", "音声"),
        ("Esc", "閉じる"),
    ]

    private var isTransform: Bool { viewModel.mode == .transform }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Chrome kept to a minimum (owner call, 2026-07-03): no pane title,
            // no character count — the L1 context chip is the only header
            // content, and the whole row disappears with it.
            if let context = viewModel.situationalContext, !viewModel.isContextExcluded {
                HStack(spacing: 8) {
                    SituationalContextChip(context: context) {
                        viewModel.excludeContext()
                    }
                    Spacer()
                }
            }

            if isTransform {
                // The received message is read-only reference material: an
                // editable field here invites confusion about what gets sent.
                ScrollView {
                    Text(viewModel.draft)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(13)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(EditorFocusBackground(isFocused: false))
            } else {
                // Enter sends the original text as-is (after the IME confirms any
                // in-progress conversion); Shift+Enter inserts a newline.
                SendableTextEditor(
                    text: $viewModel.draft,
                    focusedField: $focusedField,
                    field: .draft,
                    onSend: { viewModel.deployDraft() },
                    onEscape: { viewModel.requestPanelClose() }
                )
                    .padding(8)
                    .background(EditorFocusBackground(isFocused: isFocused))
            }

            if viewModel.needsScreenCapturePermission {
                ScreenCapturePermissionBanner(viewModel: viewModel)
            }

            HStack(spacing: 8) {
                // The hotkey cheat sheet describes compose interactions
                // (send/review/dictate), none of which exist on the read-only
                // receiving side — so the (?) button is compose-only too.
                if !isTransform {
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
                            ForEach(shortcuts, id: \.0) { key, action in
                                HStack(spacing: 8) {
                                    Text(key)
                                        .font(.caption.monospaced())
                                        .frame(width: 96, alignment: .leading)
                                    Text(action).font(.caption)
                                }
                            }
                        }
                        .padding(12)
                    }
                }

                if !isTransform {
                    Button {
                        viewModel.requestScreenshotCapture()
                    } label: {
                        Image(systemName: "camera.viewfinder")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isCapturingScreenshot)
                    .help("ビジョン入力としてスクリーンショットを撮影します")
                    .accessibilityLabel("画面を撮影して読み取る")
                }

                if viewModel.isRecording {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                    Text("録音中…").font(.caption).foregroundStyle(.secondary)
                } else if viewModel.isTranscribing {
                    ProgressView().controlSize(.small)
                    Text("文字起こし中…").font(.caption).foregroundStyle(.secondary)
                } else if viewModel.isCapturingScreenshot {
                    ProgressView().controlSize(.small)
                    Text("スクショ中…").font(.caption).foregroundStyle(.secondary)
                } else if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                // Reading a received message needs no actions on this side:
                // interpretation runs automatically and the useful exits (copy
                // the readable version / approve a reply draft) live on the
                // result pane. Review/send/copy-source buttons are compose-only.
                if !isTransform {
                    Button {
                        Task { await viewModel.runReview() }
                    } label: {
                        Label("レビュー", systemImage: "checkmark.shield")
                    }
                    .disabled(!viewModel.canReview)
                    .help("原文をレビューします")

                    Button {
                        viewModel.deployDraft()
                    } label: {
                        Label("確定", systemImage: "paperplane.fill")
                    }
                    .disabled(!viewModel.canDeployDraft)
                    .buttonStyle(.borderedProminent)
                    .help("レビューを使わず、原文のまま入力先へ確定します")
                }
            }
        }
        .padding()
    }

}

/// L1 context chip: shows which screen the review will reference. Click to
/// inspect exactly what was captured; ✕ excludes it for this session. Making
/// the captured text inspectable/removable is a privacy commitment, not a
/// nicety.
private struct SituationalContextChip: View {
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
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("この画面の内容をレビューの参考にします。クリックで内容を確認")
            .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("参照中の周辺コンテクスト").font(.headline)
                    Text(context.chipLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let excerpt = context.conversationExcerpt, !excerpt.isEmpty {
                        ScrollView {
                            Text(excerpt)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: 380, height: 220)
                    } else {
                        Text("画面のテキストは読み取れませんでした。アプリ名とウィンドウ名だけを参考にします。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 380, alignment: .leading)
                    }
                    Text("この情報は保存されず、このセッションのレビューにだけ使われます。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            Button {
                onExclude()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("このセッションでは周辺コンテクストを使いません")
            .accessibilityLabel("周辺コンテクストを除外")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

private struct ScreenCapturePermissionBanner: View {
    @ObservedObject var viewModel: ReviewViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .foregroundStyle(.orange)
            Text("スクリーンショットには画面収録の許可が必要です。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                viewModel.requestScreenCaptureSettings()
            } label: {
                Label("設定を開く", systemImage: "gearshape")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
