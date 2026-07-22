import Foundation

extension Notification.Name {
    /// Posted by `MemorySyncService` after a sync round trip actually
    /// changed local state (server had newer/other-device data). The memory
    /// page observes this to refresh without polling.
    static let memoryCardsDidSync = Notification.Name("BombSquad.memoryCardsDidSync")
}

/// Syncs local memory cards with the gateway. One `PUT /api/memory/cards`
/// round trip does both push and pull: it sends every local card (including
/// tombstones), and the gateway returns its already-merged full state
/// (last-write-wins on `updated_at`, docs/api-contract.md), which is then
/// applied back locally via `MemoryStore.applyServerState`.
///
/// Signed-out users cannot create an authenticated Gateway client, so sync is
/// a no-op and memory stays local-only.
actor MemorySyncService {
    static let shared = MemorySyncService()

    private var didStart = false
    private var isSyncing = false
    private var isSyncPending = false
    private var debounceTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?

    /// Local edits are bursty (typing, then a save); waiting this long after
    /// the last `.memoryCardsDidChange` collapses a burst into one sync.
    private static let debounceNanoseconds: UInt64 = 2_500_000_000

    private init() {}

    /// Runs one sync immediately, then starts observing local changes for
    /// future debounced syncs. Safe to call more than once — only the first
    /// call wires up the observer.
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

    /// Pushes the full local state (including tombstones) and applies back
    /// whatever the gateway returns. A no-op when the gateway isn't
    /// configured. Failures are logged only — memory sync must never
    /// surface as a user-facing error or block the rest of the app.
    ///
    /// Multiple overlapping calls coalesce: a sync already running captures
    /// at most one more pending run, so bursts of edits don't queue up an
    /// unbounded number of requests.
    func syncNow() async {
        guard GatewayAPI.make() != nil else {
            NSLog("BombSquad sync: skipped (gateway not configured or no session)")
            return
        }

        guard !isSyncing else {
            isSyncPending = true
            return
        }
        isSyncing = true
        await runSync()
        isSyncing = false

        if isSyncPending {
            isSyncPending = false
            await syncNow()
        }
    }

    // MARK: - Internals

    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func runSync() async {
        guard let client = GatewayClient.make() else { return }
        do {
            let localCards = try await MemoryStore.shared.allCardsIncludingDeleted()

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try await client.sendJSONData(
                "memory/cards",
                method: "PUT",
                body: encoder.encode(CardsWirePayload(cards: localCards))
            )

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let payload = try decoder.decode(CardsWirePayload.self, from: data)

            try await MemoryStore.shared.applyServerState(payload.cards)
            NotificationCenter.default.post(name: .memoryCardsDidSync, object: nil)
        } catch {
            NSLog("BombSquad memory sync skipped: \(error.localizedDescription)")
        }
    }
}

/// Wire shape for `GET/PUT /api/memory/cards`: `{ "cards": [...] }`.
private struct CardsWirePayload: Codable {
    let cards: [MemoryCard]
}
