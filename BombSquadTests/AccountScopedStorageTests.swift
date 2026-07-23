import XCTest
@testable import Universal_IO

final class AccountScopedStorageTests: XCTestCase {
    func testDraftAndMemoryDoNotCrossAccountBoundary() async throws {
        let firstUser = UUID()
        let secondUser = UUID()
        defer {
            FoundationComposeDraftStore.removeAccountData(userID: firstUser)
            FoundationComposeDraftStore.removeAccountData(userID: secondUser)
            try? AppSupport.removeAccountDirectory(for: firstUser)
            try? AppSupport.removeAccountDirectory(for: secondUser)
            FoundationComposeDraftStore.activateAccount(userID: nil)
        }

        FoundationComposeDraftStore.activateAccount(userID: firstUser)
        FoundationComposeDraftStore.save("first account draft")
        FoundationComposeDraftStore.activateAccount(userID: secondUser)
        XCTAssertEqual(FoundationComposeDraftStore.load(), "")
        FoundationComposeDraftStore.activateAccount(userID: firstUser)
        XCTAssertEqual(FoundationComposeDraftStore.load(), "first account draft")

        let store = MemoryStore()
        try await store.activateAccount(userID: firstUser)
        try await store.savePersona(contentMD: "first account memory", source: .userEdited)
        let firstAccountMemory = try await store.personaCard()
        XCTAssertEqual(firstAccountMemory?.contentMD, "first account memory")

        try await store.activateAccount(userID: secondUser)
        let secondAccountMemory = try await store.personaCard()
        XCTAssertNil(secondAccountMemory)

        try await store.activateAccount(userID: firstUser)
        let restoredFirstAccountMemory = try await store.personaCard()
        XCTAssertEqual(restoredFirstAccountMemory?.contentMD, "first account memory")
        try await store.activateAccount(userID: nil)
    }

    func testConflictRemainsPendingAcrossSyncRounds() async throws {
        let userID = UUID()
        defer { try? AppSupport.removeAccountDirectory(for: userID) }

        let store = MemoryStore()
        try await store.activateAccount(userID: userID)
        try await store.savePersona(contentMD: "local edit", source: .userEdited)
        let fetchedLocal = try await store.personaCard()
        let local = try XCTUnwrap(fetchedLocal)
        let cloud = MemoryCard(
            id: local.id,
            kind: .persona,
            subject: nil,
            contentMD: "cloud edit",
            source: .userEdited,
            createdAt: local.createdAt,
            updatedAt: Date(timeIntervalSince1970: local.updatedAt.timeIntervalSince1970 + 10),
            deletedAt: nil
        )
        try await store.applySyncResponse(
            MemorySyncResponse(
                cards: [cloud],
                syncedIDs: [],
                conflicts: [cloud],
                cursor: cloud.updatedAt,
                hasMore: false
            )
        )

        let pending = try await store.pendingSyncRecords(limit: 1)
        XCTAssertEqual(pending.map(\.id), [local.id])
        let preservedLocal = try await store.personaCard()
        XCTAssertEqual(preservedLocal?.contentMD, "local edit")
        try await store.activateAccount(userID: nil)
    }
}
