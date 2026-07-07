import SwiftUI

/// Receiving-side layout: the received message on top (read-only reference
/// material), the shared "understand → respond" interpretation below. Every
/// exit copies to the clipboard — nothing is ever written back to the sender.
struct TransformContentView: View {
    @ObservedObject var session: TransformSession

    var body: some View {
        VStack(spacing: 0) {
            sourcePane
                .frame(maxHeight: session.isLoading ? 190 : .infinity)
            resultPane
                .frame(maxHeight: .infinity)
        }
        .animation(.spring(duration: 0.35), value: session.isLoading)
        .frame(minWidth: 620, minHeight: 640)
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let context = session.situationalContext, !session.isContextExcluded {
                HStack(spacing: 8) {
                    SituationalContextChip(context: context) {
                        session.excludeContext()
                    }
                    Spacer()
                }
            }

            // The received message is read-only reference material: an
            // editable field here invites confusion about what gets sent.
            ScrollView {
                Text(session.sourceText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(EditorFocusBackground(isFocused: false))
        }
        .padding()
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("読み取り結果", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                if session.interpretation != nil {
                    Button {
                        session.copyInterpretation()
                    } label: {
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

            if let message = session.errorMessage {
                ErrorBanner(message: message)
            }

            if let interpretation = session.interpretation {
                // The received message goes through the same "understand →
                // respond" view as a screenshot. Approving an action copies
                // the draft (never writes back to the sender).
                VisionInterpretationView(
                    result: interpretation,
                    isTransform: true,
                    onApprove: { session.approve($0) },
                    onEdit: { _ in }
                )
            } else if session.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("読みやすく整理しています…")
                        .foregroundStyle(.secondary)
                }
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
        .padding()
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
}
