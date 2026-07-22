import SwiftUI

/// The memory page: everything I//O has learned about the user, fully visible
/// and editable. Persona card (own style) on top, relationship cards below.
/// Transparency is the point — "this is how I//O understands you" builds the
/// trust that lets the app read screens and messages.
struct MemoryView: View {
    @StateObject private var viewModel = MemoryViewModel()
    @ObservedObject private var noticeCenter = OperationalNoticeCenter.shared
    @AppStorage(AppSettings.isMemoryEnabledKey) private var isMemoryEnabled = true

    var body: some View {
        Form {
            if let notice = noticeCenter.current {
                Section {
                    OperationalNoticeBanner(
                        message: notice.message,
                        onDismiss: noticeCenter.dismiss
                    )
                }
            }
            if !isMemoryEnabled {
                Section {
                    Label("メモリは現在オフです。カードの閲覧・編集はできますが、レビューへの反映と学習は行われません。", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("あなたのスタイルプロファイル") {
                if let persona = viewModel.personaCard {
                    personaEditor(persona)
                } else {
                    bootstrapFlow
                }
            }

            Section("相手ごとのメモ") {
                if viewModel.relationshipCards.isEmpty {
                    Text("まだありません。レビューを使って送信すると、相手ごとの敬語レベルや呼称のメモが自動的に育ちます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.relationshipCards) { card in
                        relationshipRow(card)
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("メモリ")
        .task { await viewModel.reload() }
    }

    // MARK: - Persona

    @ViewBuilder
    private func personaEditor(_ persona: MemoryCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("レビュー時に毎回参照され、修正文があなたの文体に寄ります。内容は自由に編集できます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $viewModel.personaDraft)
                .font(.body.monospaced())
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("\(sourceLabel(persona.source)) · 更新 \(Self.dateFormatter.string(from: persona.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("削除", role: .destructive) {
                    Task { await viewModel.deletePersona() }
                }
                Button("保存") {
                    Task { await viewModel.savePersonaDraft() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.personaDraft == persona.contentMD)
            }
        }
        .padding(.vertical, 4)
    }

    private var bootstrapFlow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("あなたが過去に実際に送ったメール・メッセージを 3〜5 通貼り付けてください。文体・敬語レベル・記号の癖を抽出してプロファイルを作成します（内容そのものは保存されません）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $viewModel.bootstrapSamples)
                .font(.body)
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                if let hint = bootstrapHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.isGenerating {
                    ProgressView().controlSize(.small)
                    Text("プロファイルを生成中…").font(.caption).foregroundStyle(.secondary)
                }
                Button("プロファイルを生成") {
                    Task { await viewModel.generatePersona() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isBootstrapReady || viewModel.isGenerating)
            }
        }
        .padding(.vertical, 4)
    }

    private static let bootstrapMinimumLength = 50

    private var isBootstrapReady: Bool {
        viewModel.bootstrapSamples.trimmingCharacters(in: .whitespacesAndNewlines).count
            >= Self.bootstrapMinimumLength
    }

    /// Explains why the button is disabled — otherwise it silently refuses
    /// short pastes with no feedback.
    private var bootstrapHint: String? {
        guard !viewModel.isGenerating else { return nil }
        let count = viewModel.bootstrapSamples.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard count < Self.bootstrapMinimumLength else { return nil }
        let remaining = Self.bootstrapMinimumLength - count
        return "あと \(remaining) 文字以上入力してください（過去のメッセージを3〜5通貼り付けると生成できます）"
    }

    // MARK: - Relationships

    private func relationshipRow(_ card: MemoryCard) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: viewModel.relationshipDraftBinding(for: card))
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text("更新 \(Self.dateFormatter.string(from: card.updatedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("削除", role: .destructive) {
                        Task { await viewModel.deleteCard(card) }
                    }
                    Button("保存") {
                        Task { await viewModel.saveRelationshipDraft(for: card) }
                    }
                    .disabled(viewModel.relationshipDrafts[card.id] == nil
                              || viewModel.relationshipDrafts[card.id] == card.contentMD)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                Text(card.subject ?? "（名前なし）")
                    .font(.body.weight(.medium))
            }
        }
    }

    // MARK: - Helpers

    private func sourceLabel(_ source: MemoryCard.Source) -> String {
        switch source {
        case .bootstrap: return "ブートストラップ生成"
        case .distilled: return "自動学習"
        case .userEdited: return "手動編集"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()
}

/// State for the memory page: loads cards, runs the bootstrap generation, and
/// saves edits back through `MemoryStore`.
@MainActor
final class MemoryViewModel: ObservableObject {
    @Published private(set) var personaCard: MemoryCard?
    @Published private(set) var relationshipCards: [MemoryCard] = []
    @Published var personaDraft: String = ""
    @Published var relationshipDrafts: [String: String] = [:]
    @Published var bootstrapSamples: String = ""
    @Published var isGenerating = false
    @Published var errorMessage: String?

    private var syncObserver: NSObjectProtocol?

    init() {
        // Another device's edit landed via sync — refresh so it shows up
        // here without the user having to reopen the page.
        syncObserver = NotificationCenter.default.addObserver(
            forName: .memoryCardsDidSync, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.reload() }
        }
    }

    deinit {
        if let syncObserver {
            NotificationCenter.default.removeObserver(syncObserver)
        }
    }

    func reload() async {
        do {
            personaCard = try await MemoryStore.shared.personaCard()
            personaDraft = personaCard?.contentMD ?? ""
            relationshipCards = try await MemoryStore.shared.relationshipCards()
            relationshipDrafts = Dictionary(
                uniqueKeysWithValues: relationshipCards.map { ($0.id, $0.contentMD) }
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generatePersona() async {
        OperationalNoticeCenter.shared.beginOperation()
        errorMessage = nil
        isGenerating = true
        defer { isGenerating = false }
        do {
            let card = try await MemoryDistiller.generatePersonaCard(fromSamples: bootstrapSamples)
            try await MemoryStore.shared.savePersona(contentMD: card, source: .bootstrap)
            bootstrapSamples = ""
            await reload()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func savePersonaDraft() async {
        guard let personaCard else { return }
        do {
            try await MemoryStore.shared.updateCard(
                id: personaCard.id, contentMD: personaDraft, source: .userEdited
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePersona() async {
        guard let personaCard else { return }
        await deleteCard(personaCard)
    }

    func deleteCard(_ card: MemoryCard) async {
        do {
            try await MemoryStore.shared.deleteCard(id: card.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func relationshipDraftBinding(for card: MemoryCard) -> Binding<String> {
        Binding(
            get: { self.relationshipDrafts[card.id] ?? card.contentMD },
            set: { self.relationshipDrafts[card.id] = $0 }
        )
    }

    func saveRelationshipDraft(for card: MemoryCard) async {
        guard let draft = relationshipDrafts[card.id] else { return }
        do {
            try await MemoryStore.shared.updateCard(id: card.id, contentMD: draft, source: .userEdited)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
