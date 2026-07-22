import Foundation

struct HistoryEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let sourceText: String
    let finalText: String
    let modelID: String?
    let modelName: String?
    let outputLanguage: String?

    var usedReview: Bool {
        modelName != nil
    }
}

struct HistoryEntryInput: Sendable {
    let sourceText: String
    let finalText: String
    let modelID: String?
    let modelName: String?
    let outputLanguage: String?
}
