import SwiftUI

struct HistoryPlaceholderView: View {
    @StateObject private var viewModel = HistoryViewModel()
    @AppStorage(AppSettings.isHistoryEnabledKey) private var isHistoryEnabled = true

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.entries.isEmpty {
                ProgressView("履歴を読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.entries.isEmpty {
                emptyState
            } else {
                List(viewModel.entries) { entry in
                    HistoryRow(entry: entry)
                }
                .listStyle(.inset)
            }
        }
        .overlay(alignment: .top) {
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.red)
                    .padding()
            }
        }
        .safeAreaInset(edge: .top) {
            if !isHistoryEnabled {
                Label("新しい履歴の保存は現在オフです。既存の履歴だけ表示しています。", systemImage: "tray")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
        }
        .navigationTitle("履歴")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("削除") {
                    Task { await viewModel.clear() }
                }
                .disabled(viewModel.entries.isEmpty)
            }
        }
        .task {
            await viewModel.reload()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("履歴")
                .font(.title2.weight(.semibold))
            Text("実際に送信した内容を、最新 \(AppSettings.localHistoryLimit) 件までこの Mac に保存します。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("送信")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Text(Self.formatter.string(from: entry.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            textBlock(title: "送信文", text: entry.finalText)

            // The before→after gap is the product's core artifact; show it on
            // demand for entries that went through a review.
            if entry.usedReview, entry.sourceText != entry.finalText {
                DisclosureGroup("変更点（原文 → 送信文）") {
                    DiffView(original: entry.sourceText, revised: entry.finalText)
                        .frame(maxHeight: 180)
                }
                .font(.caption)
            }

            HStack(spacing: 8) {
                Text(entry.usedReview ? (entry.modelName ?? "レビューあり") : "レビューなし")
                if let outputLanguage = entry.outputLanguage {
                    Text(outputLanguage)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func textBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
