import Foundation

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let historyStore: HistoryStore

    init(historyStore: HistoryStore = LocalHistoryStore.shared) {
        self.historyStore = historyStore
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            entries = try await historyStore.fetchEntries(limit: AppSettings.localHistoryLimit)
        } catch {
            errorMessage = "履歴の読み込みに失敗しました。時間をおいて、もう一度お試しください。"
        }
    }

    func clear() async {
        errorMessage = nil
        do {
            try await historyStore.clear()
            entries = []
        } catch {
            errorMessage = "履歴の削除に失敗しました。もう一度お試しください。"
        }
    }
}
