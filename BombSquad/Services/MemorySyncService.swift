import Combine
import Foundation

extension Notification.Name {
    static let memoryCardsDidSync = Notification.Name("BombSquad.memoryCardsDidSync")
}

enum MemorySyncStatus: Equatable {
    case inactive
    case syncing
    case synced(Date)
    case failed(String)
    case conflict(Int)
}

@MainActor
final class MemorySyncStatusStore: ObservableObject {
    static let shared = MemorySyncStatusStore()
    @Published private(set) var status: MemorySyncStatus = .inactive

    private init() {}

    func update(_ status: MemorySyncStatus) {
        self.status = status
    }
}

/// One dirty local card plus the authoritative server version on which the
/// edit was based. Card timestamps remain useful for local display, but the
/// gateway uses `base_updated_at` for conflict detection and assigns the next
/// `updated_at` itself.
struct MemoryUploadRecord: Codable {
    let id: String
    let kind: MemoryCard.Kind
    let subject: String?
    let contentMD: String
    let source: MemoryCard.Source
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let baseServerUpdatedAt: Date?

    init(card: MemoryCard, baseServerUpdatedAt: Date?) {
        id = card.id
        kind = card.kind
        subject = card.subject
        contentMD = card.contentMD
        source = card.source
        createdAt = card.createdAt
        updatedAt = card.updatedAt
        deletedAt = card.deletedAt
        self.baseServerUpdatedAt = baseServerUpdatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, subject, source
        case contentMD = "content_md"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case baseServerUpdatedAt = "base_updated_at"
    }
}

struct MemorySyncResponse: Codable {
    let cards: [MemoryCard]
    let syncedIDs: [String]
    let conflicts: [MemoryCard]
    let cursor: Date?
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case cards, conflicts, cursor
        case syncedIDs = "synced_ids"
        case hasMore = "has_more"
    }
}

private struct MemorySyncRequest: Codable {
    let cards: [MemoryUploadRecord]
    let cursor: Date?
}

/// Account-scoped, incremental memory sync. Local changes are sent in bounded
/// batches and the response contains only server rows newer than the client's
/// cursor. A base-version mismatch becomes an explicit conflict; neither copy
/// is discarded until the user chooses which one should win.
actor MemorySyncService {
    static let shared = MemorySyncService()

    private var didStart = false
    private var isSyncing = false
    private var isSyncPending = false
    private var debounceTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var conflictCards: [MemoryCard] = []

    private static let debounceNanoseconds: UInt64 = 2_500_000_000
    private static let maxPagesPerRound = 20

    private init() {}

    func start() {
        Task { await syncNow() }
        guard !didStart else { return }
        didStart = true

        changeObserver = NotificationCenter.default.addObserver(
            forName: .memoryCardsDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.scheduleDebouncedSync() }
        }
    }

    func syncNow() async {
        guard GatewayAPI.make() != nil,
              BombSquadAuthClient.shared.currentUserID() != nil
        else {
            await MemorySyncStatusStore.shared.update(.inactive)
            return
        }

        guard !isSyncing else {
            isSyncPending = true
            return
        }
        isSyncing = true
        await MemorySyncStatusStore.shared.update(.syncing)
        await runSync()
        isSyncing = false

        if isSyncPending {
            isSyncPending = false
            await syncNow()
        }
    }

    func resolveConflictsUsingLocal() async {
        guard !conflictCards.isEmpty else { return }
        do {
            try await MemoryStore.shared.resolveConflictsUsingLocal(conflictCards)
            conflictCards = []
            await syncNow()
        } catch {
            await MemorySyncStatusStore.shared.update(.failed(error.localizedDescription))
        }
    }

    func resolveConflictsUsingCloud() async {
        guard !conflictCards.isEmpty else { return }
        do {
            try await MemoryStore.shared.resolveConflictsUsingCloud(conflictCards)
            conflictCards = []
            await MemorySyncStatusStore.shared.update(.synced(Date()))
        } catch {
            await MemorySyncStatusStore.shared.update(.failed(error.localizedDescription))
        }
    }

    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func runSync() async {
        guard let client = GatewayClient.make(),
              let syncingUserID = BombSquadAuthClient.shared.currentUserID()
        else { return }

        do {
            var allConflicts: [String: MemoryCard] = [:]
            var serverHasMorePages = false
            for _ in 0..<Self.maxPagesPerRound {
                let records = try await MemoryStore.shared.pendingSyncRecords()
                let cursor = try await MemoryStore.shared.syncCursor()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                let body = try encoder.encode(MemorySyncRequest(cards: records, cursor: cursor))
                let data = try await client.sendJSONData(
                    "memory/cards",
                    method: "PUT",
                    body: body
                )

                // A sign-out/account switch can finish while the request is in
                // flight. Never apply the old account's response to the newly
                // activated local database.
                guard BombSquadAuthClient.shared.currentUserID() == syncingUserID else {
                    return
                }

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                let response = try decoder.decode(MemorySyncResponse.self, from: data)
                try await MemoryStore.shared.applySyncResponse(response)
                serverHasMorePages = response.hasMore
                for card in response.conflicts { allConflicts[card.id] = card }

                // Conflict rows stay pending so a later app launch can fetch
                // the cloud copy again and reconstruct the resolution UI.
                // Stop this round immediately instead of resending the same
                // unresolved edit up to the page limit.
                if !response.conflicts.isEmpty { break }

                let hasPending = !(try await MemoryStore.shared.pendingSyncRecords(limit: 1)).isEmpty
                if !response.hasMore && !hasPending { break }
            }

            conflictCards = Array(allConflicts.values)
            if conflictCards.isEmpty {
                let hasPending = !(try await MemoryStore.shared.pendingSyncRecords(limit: 1)).isEmpty
                if serverHasMorePages || hasPending {
                    // Continue in a fresh bounded round instead of reporting a
                    // false success when a very old account has >2,000 local
                    // tombstones or server changes to reconcile.
                    isSyncPending = true
                } else {
                    await MemorySyncStatusStore.shared.update(.synced(Date()))
                }
            } else {
                await MemorySyncStatusStore.shared.update(.conflict(conflictCards.count))
            }
            NotificationCenter.default.post(name: .memoryCardsDidSync, object: nil)
        } catch {
            await MemorySyncStatusStore.shared.update(.failed(error.localizedDescription))
            NSLog("Universal I/O memory sync failed: \(error.localizedDescription)")
        }
    }
}
