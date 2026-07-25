import Foundation

@MainActor
final class FactsViewModel: ObservableObject {
    @Published private(set) var groups: [UserFactGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var maxValueChars = 120
    @Published var errorMessage: String?

    private let client: GatewayFactsClient?

    init(client: GatewayFactsClient? = GatewayFactsClient.make()) {
        self.client = client
    }

    var learnedCount: Int {
        groups.reduce(0) { $0 + $1.learnedCount }
    }

    func reload() async {
        guard let client else {
            errorMessage = "ログインすると、覚えている内容を確認できます。"
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await client.fetchFacts()
            maxValueChars = result.maxValueChars
            groups = Self.grouped(result.facts)
        } catch {
            errorMessage = "覚えている内容を読み込めませんでした。時間をおいて、もう一度お試しください。"
        }
    }

    /// Saves an edited value, or deletes the fact when the field was emptied —
    /// clearing the box is how a user says "forget this".
    func commit(_ fact: UserFact, value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (fact.value ?? "") else { return }
        if trimmed.isEmpty {
            await delete(fact)
            return
        }
        guard let client else { return }
        errorMessage = nil
        do {
            try await client.save(scope: fact.scope, key: fact.key, value: trimmed)
            apply(scope: fact.scope, key: fact.key, value: trimmed)
        } catch {
            errorMessage = "保存できませんでした。もう一度お試しください。"
            await reload()
        }
    }

    func delete(_ fact: UserFact) async {
        guard let client else { return }
        errorMessage = nil
        do {
            try await client.delete(scope: fact.scope, key: fact.key)
            apply(scope: fact.scope, key: fact.key, value: nil)
        } catch {
            errorMessage = "削除できませんでした。もう一度お試しください。"
            await reload()
        }
    }

    private func apply(scope: String, key: String, value: String?) {
        for groupIndex in groups.indices {
            guard groups[groupIndex].scope == scope else { continue }
            for factIndex in groups[groupIndex].facts.indices
            where groups[groupIndex].facts[factIndex].key == key {
                groups[groupIndex].facts[factIndex].value = value
                groups[groupIndex].facts[factIndex].updatedAt = value == nil ? nil : Date()
            }
        }
    }

    /// Keeps the gateway's order, which is global first and then one section per
    /// skill, so the list reads the same way the vocabulary is declared.
    private static func grouped(_ facts: [UserFact]) -> [UserFactGroup] {
        var groups: [UserFactGroup] = []
        for fact in facts {
            if let index = groups.firstIndex(where: { $0.scope == fact.scope }) {
                groups[index].facts.append(fact)
            } else {
                groups.append(
                    UserFactGroup(scope: fact.scope, label: fact.scopeLabel, facts: [fact])
                )
            }
        }
        return groups
    }
}
