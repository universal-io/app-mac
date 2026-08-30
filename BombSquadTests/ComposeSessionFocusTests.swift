import XCTest
@testable import Universal_IO

final class ComposeSessionFocusTests: XCTestCase {
    @MainActor
    func testReviewCompletionKeepsDraftAsExplicitDefault() async throws {
        let defaults = UserDefaults.standard
        let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let draftKey = "foundation.composeDraft.\(userID.uuidString.lowercased())"
        let previousDraft = defaults.object(forKey: draftKey)
        FoundationComposeDraftStore.activateAccount(userID: userID)
        defer {
            FoundationComposeDraftStore.activateAccount(userID: nil)
            if let previousDraft {
                defaults.set(previousDraft, forKey: draftKey)
            } else {
                defaults.removeObject(forKey: draftKey)
            }
        }

        let contextTask = Task<SituationalContext?, Never> { nil }
        let session = ComposeSession(
            deployer: FocusTestDeployer(),
            contextCaptureTask: contextTask,
            provider: FocusTestReviewProvider()
        )
        session.draft = "自分で入力した原文"
        session.focusedField = .draft

        session.requestReview()
        for _ in 0..<100 where session.result == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNotNil(session.result)
        XCTAssertEqual(session.revisedDraft, "AIによるレビュー案")
        XCTAssertEqual(session.focusedField, .draft)

        session.toggleFocusedField()
        XCTAssertEqual(session.focusedField, .revision)
    }

    /// The 自動返信 button takes the result surface over from a review — the
    /// mirror of a review claiming it. Everything the review put up comes
    /// down, including the chip's record of what was reviewed; the draft the
    /// user wrote is untouched.
    @MainActor
    func testTakingTheReviewSurfaceDownClearsItsOutputButNotTheDraft() async throws {
        let defaults = UserDefaults.standard
        let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let draftKey = "foundation.composeDraft.\(userID.uuidString.lowercased())"
        let previousDraft = defaults.object(forKey: draftKey)
        FoundationComposeDraftStore.activateAccount(userID: userID)
        defer {
            FoundationComposeDraftStore.activateAccount(userID: nil)
            if let previousDraft {
                defaults.set(previousDraft, forKey: draftKey)
            } else {
                defaults.removeObject(forKey: draftKey)
            }
        }

        let contextTask = Task<SituationalContext?, Never> { nil }
        let session = ComposeSession(
            deployer: FocusTestDeployer(),
            contextCaptureTask: contextTask,
            provider: FocusTestReviewProvider()
        )
        session.draft = "自分で入力した原文"
        session.focusedField = .draft

        session.requestReview()
        for _ in 0..<100 where session.result == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(session.result)
        XCTAssertEqual(session.reviewedDraft, "自分で入力した原文")
        session.focusedField = .revision

        session.takeDownReviewSurface()

        XCTAssertNil(session.result)
        XCTAssertNil(session.reviewedDraft)
        XCTAssertEqual(session.revisedDraft, "")
        XCTAssertFalse(session.isReviewing)
        XCTAssertEqual(session.draft, "自分で入力した原文")
        XCTAssertEqual(session.focusedField, .draft)
    }

}

private final class FocusTestDeployer: Deployer {
    private(set) var deployedTexts: [String] = []

    func deploy(_ text: String) throws {
        deployedTexts.append(text)
    }
}

private struct FocusTestReviewProvider: ReviewProvider {
    func review(
        draft: String,
        language: OutputLanguage,
        context: SituationalContext?
    ) async throws -> ReviewResult {
        ReviewResult(
            issues: [],
            revisedText: "AIによるレビュー案",
            summary: "テスト用レビュー"
        )
    }
}
