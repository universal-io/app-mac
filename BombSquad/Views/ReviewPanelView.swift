import AppKit
import SwiftUI

/// Bottom pane of the compose layout: the review findings, the diff, the
/// editable revision, and the "deploy to live" action. (Compose-only since
/// R1-a; the receiving side lives in TransformContentView, vision in
/// VisionPanelView.)
struct ReviewPanelView: View {
    @ObservedObject var session: ComposeSession
    /// Shared focus across both editors (drives the blue highlight).
    @Binding var focusedField: FocusField?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(headerTitle, systemImage: headerSystemImage)
                    .font(.headline)
                Spacer()
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

            if let result = session.result {
                resultBody(result)
            } else if let streaming = session.streamingRevision, !streaming.isEmpty {
                streamingBody(streaming)
            } else if session.isLoading {
                loadingState
            } else {
                emptyState
            }
        }
        .padding()
        .animation(.easeInOut(duration: 0.18), value: session.result != nil)
        .animation(.easeInOut(duration: 0.18), value: session.isLoading)
        .overlay(alignment: .bottom) {
            if session.didDeploy {
                Label("入力先へ確定しました", systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.green.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: session.didDeploy)
        .task {
            await session.loadRecentHistoryIfNeeded()
        }
    }

    @ViewBuilder
    private func resultBody(_ result: ReviewResult) -> some View {
        if session.needsReReview {
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
            text: $session.revisedDraft,
            focusedField: $focusedField,
            field: .revision,
            onSend: { session.deployRevision() }
        )
            .padding(8)
            .frame(maxHeight: .infinity)
            .background(EditorFocusBackground(isFocused: focusedField == .revision))

        HStack {
            Spacer()
            Button {
                session.deployRevision()
            } label: {
                Label("確定", systemImage: "paperplane.fill")
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

                DiffView(original: session.draft, revised: session.revisedDraft)
                    .frame(minHeight: 96, maxHeight: 180)

                if result.issues.isEmpty {
                    Label("指摘はありません。そのまま送れます。",
                          systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(result.sortedIssues) { IssueCard(issue: $0) }
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

    /// While the review runs, fill the result field with a spinner so the
    /// panel shows progress the instant the review starts.
    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("レビュー中…")
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
            if !session.recentHistoryEntries.isEmpty {
                recentHistoryState
            } else if session.isLoadingRecentHistory {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("履歴を読み込み中…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
                .background(EditorFocusBackground(isFocused: false))
            } else {
                Text("レビュー結果がここに表示されます\n\nまだ履歴がありません。")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
                    .background(EditorFocusBackground(isFocused: false))
            }
        }
    }

    private var recentHistoryState: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(session.recentHistoryEntries) { entry in
                Button {
                    session.applyRecentHistory(entry)
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
        if session.result == nil, !session.isLoading {
            return "最近の履歴"
        }
        return "レビュー結果"
    }

    private var headerSystemImage: String {
        if session.result == nil, !session.isLoading {
            return "clock.arrow.circlepath"
        }
        return "text.magnifyingglass"
    }

    private static let recentHistoryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()
}

/// Tiny badge shown next to the model info when the gateway is overridden
/// away from the production default (e.g. localhost during development).
/// Replaces the old full-width orange banner, which was visually too loud.
struct GatewayOverrideBadge: View {
    var body: some View {
        if BombSquadConfig.isUsingOverriddenGateway() {
            Text("開発GW")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange, in: Capsule())
                .help("開発Gatewayに接続中: \(BombSquadConfig.resolvedAPIBaseURL() ?? "?")")
        }
    }
}

/// Shared error banner. The message is a `Text` (not a `Label`) so it can be
/// selected and copied — essential for reporting gateway/provider errors.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.red)
    }
}

/// A single finding card (compose: fixes the sender should adopt).
private struct IssueCard: View {
    let issue: ReviewIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(issue.category.label)
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
                Text("→ \(issue.suggestion)")
                    .font(.callout)
                    .foregroundStyle(.blue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var categoryColor: Color {
        switch issue.category {
        case .typo: return .orange
        case .impoliteness: return .red
        case .unclear: return .purple
        }
    }
}
