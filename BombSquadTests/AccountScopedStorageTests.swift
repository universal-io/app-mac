import XCTest
@testable import Universal_IO

final class AccountScopedStorageTests: XCTestCase {
    func testDraftsDoNotCrossAccountBoundary() async throws {
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
    }
}
