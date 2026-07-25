import SwiftUI

/// Everything the app is allowed to remember about the user, editable and
/// deletable in place. This screen is the guarantee the fact store rests on:
/// the vocabulary is closed and small precisely so it can be shown in full,
/// rather than kept trustworthy by confidence scores the user cannot see.
struct FactsView: View {
    @StateObject private var viewModel = FactsViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.groups.isEmpty {
                ProgressView("読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.groups.isEmpty {
                emptyState
            } else {
                Form {
                    Section {
                        Text("画面から読み取った内容は、保存する前に必ず確認します。ここでいつでも書き換え・削除ができます。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.groups) { group in
                        Section(group.label) {
                            ForEach(group.facts) { fact in
                                FactRow(
                                    fact: fact,
                                    maxValueChars: viewModel.maxValueChars,
                                    onCommit: { value in
                                        Task { await viewModel.commit(fact, value: value) }
                                    },
                                    onDelete: {
                                        Task { await viewModel.delete(fact) }
                                    }
                                )
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .overlay(alignment: .top) {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
                    .padding()
            }
        }
        .navigationTitle("覚えていること")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("再読み込み") {
                    Task { await viewModel.reload() }
                }
                .disabled(viewModel.isLoading)
            }
        }
        .task { await viewModel.reload() }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("覚えていること")
                .font(.title2.weight(.semibold))
            Text("使っているツールごとに、文案づくりへ役立つ事実だけを覚えます。覚える項目はあらかじめ決まっていて、増え続けることはありません。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FactRow: View {
    let fact: UserFact
    let maxValueChars: Int
    let onCommit: (String) -> Void
    let onDelete: () -> Void

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.label)
                if let updatedAt = fact.updatedAt {
                    Text("更新: \(Self.formatter.string(from: updatedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            TextField("未登録", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($isFocused)
                .onSubmit { commit() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .accessibilityLabel(fact.label)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!fact.isLearned)
            .help("この項目を忘れる")
            .accessibilityLabel("\(fact.label) を忘れる")
        }
        .padding(.vertical, 2)
        .onAppear { draft = fact.value ?? "" }
        .onChange(of: fact.value) { _, value in
            guard !isFocused else { return }
            draft = value ?? ""
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maxValueChars {
            draft = String(trimmed.prefix(maxValueChars))
        }
        onCommit(draft)
    }
}
