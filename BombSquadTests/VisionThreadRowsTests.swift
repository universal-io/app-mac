import AppKit
import Foundation
import XCTest
@testable import Universal_IO

/// The rows the bubble's thread is drawn from.
///
/// The bubble used to overwrite one question and one answer with the next. The
/// thread keeps them, in order, and adds at most one trailing row for what is
/// happening now. These pin which row that is, and where guidance's note sits.
@MainActor
final class VisionThreadRowsTests: XCTestCase {
    private func turn(_ role: VisionTurn.Role, _ text: String) -> VisionDisplayTurn {
        VisionDisplayTurn(role: role, text: text, mode: nil, uncertainties: [])
    }

    private func rows(
        turns: [VisionDisplayTurn] = [],
        streaming: String? = nil,
        isLoading: Bool = false,
        isPointing: Bool = false,
        checking: Bool = false,
        error: String? = nil,
        refusal: String? = nil,
        sawNoChange: Bool = false
    ) -> [VisionThreadRow] {
        VisionThreadRow.rows(
            turns: turns,
            streamingMessage: streaming,
            isLoading: isLoading,
            isPointing: isPointing,
            isCopilotChecking: checking,
            errorMessage: error,
            refusal: refusal,
            copilotSawNoChange: sawNoChange
        )
    }

    private func texts(_ rows: [VisionThreadRow]) -> [String] {
        rows.map { row in
            switch row {
            case .user(_, let t): return "user:\(t)"
            case .assistant(_, let t): return "assistant:\(t)"
            case .streaming(let t): return "streaming:\(t)"
            case .waiting(let t): return "waiting:\(t)"
            case .note(let t): return "note:\(t)"
            case .error(let t): return "error:\(t)"
            case .hint(let t): return "hint:\(t)"
            }
        }
    }

    /// Every turn stays, in the order it happened. This is the whole point.
    func testEveryTurnIsKeptInOrder() {
        let rows = rows(turns: [
            turn(.user, VisionSession.pointedHereText),
            turn(.assistant, "これは保存ボタンです。"),
            turn(.user, "押すと何が起きますか"),
            turn(.assistant, "下書きが保存されます。"),
        ])
        XCTAssertEqual(texts(rows), [
            "user:ここについて",
            "assistant:これは保存ボタンです。",
            "user:押すと何が起きますか",
            "assistant:下書きが保存されます。",
        ])
    }

    /// The gesture is shown as the user's turn — a wordless question is still
    /// one, and without it the first answer would have nothing above it.
    func testTheGestureIsTheUsersFirstTurn() {
        let point = rows(turns: [turn(.user, VisionSession.pointedHereText)], isLoading: true, isPointing: true)
        XCTAssertEqual(texts(point), ["user:ここについて", "waiting:\(VisionThreadRow.readingHere)"])
        let region = rows(turns: [turn(.user, VisionSession.pointedRegionText)], isLoading: true, isPointing: true)
        XCTAssertEqual(texts(region).first, "user:この範囲について")
    }

    /// The draft is the last row while it arrives, and it is on the product's
    /// side — it becomes the answer, so it has to be where the answer will be.
    func testTheStreamingDraftIsTheLastRow() {
        let rows = rows(
            turns: [turn(.user, "これは何ですか")],
            streaming: "これは"
        )
        XCTAssertEqual(texts(rows), ["user:これは何ですか", "streaming:これは"])
        XCTAssertTrue(rows.last?.isFromProduct == true)
    }

    /// An empty draft is not a draft. While loading with nothing arrived, the
    /// bubble says what it is waiting for — and which wait it is.
    func testAnEmptyDraftShowsTheWaitInstead() {
        XCTAssertEqual(
            texts(rows(streaming: "", isLoading: true, isPointing: false)),
            ["waiting:\(VisionThreadRow.readingScreen)"]
        )
        XCTAssertEqual(
            texts(rows(streaming: nil, isLoading: true, isPointing: true)),
            ["waiting:\(VisionThreadRow.readingHere)"]
        )
    }

    /// A guidance step being evaluated is the same wait in the same words. It
    /// yields to an error.
    func testAGuidanceCheckIsTheSameWait() {
        let step = rows(turns: [turn(.assistant, "テクノロジーを開いてください")], checking: true)
        XCTAssertEqual(texts(step).last, "waiting:\(VisionThreadRow.readingScreen)")
        let failed = rows(checking: true, error: "確認できませんでした")
        XCTAssertEqual(texts(failed), ["error:確認できませんでした"])
    }

    /// An error outranks a draft: a draft that failed is not something to keep
    /// reading. The refusal banner has its own place, so it is not repeated.
    func testAnErrorOutranksTheDraftAndTheRefusalIsNotRepeated() {
        let failed = rows(streaming: "途中まで", isLoading: true, error: "失敗しました")
        XCTAssertEqual(texts(failed), ["error:失敗しました"])
        let refused = rows(error: "利用できません", refusal: "利用できません")
        XCTAssertEqual(texts(refused), ["hint:\(VisionThreadRow.emptyHint)"])
    }

    /// Nothing said and nothing coming: the bubble says what pointing does.
    /// Anything at all in the thread, and it says nothing of the sort.
    func testTheHintAppearsOnlyWhenThereIsNothingElse() {
        XCTAssertEqual(texts(rows()), ["hint:\(VisionThreadRow.emptyHint)"])
        XCTAssertFalse(texts(rows(isLoading: true)).contains { $0.hasPrefix("hint:") })
        XCTAssertFalse(texts(rows(turns: [turn(.assistant, "答え")])).contains { $0.hasPrefix("hint:") })
    }

    /// Guidance's note goes before the step it qualifies: the screen had not
    /// changed, *and so* the step was asked for again. While that step is still
    /// being evaluated, the note is the last thing said.
    func testTheNoChangeNoteSitsBeforeTheStepItQualifies() {
        let settled = rows(
            turns: [
                turn(.user, "デバイス別に見たい"),
                turn(.assistant, "テクノロジーを開いてください"),
                turn(.assistant, "テクノロジーを開いてください"),
            ],
            sawNoChange: true
        )
        XCTAssertEqual(texts(settled), [
            "user:デバイス別に見たい",
            "assistant:テクノロジーを開いてください",
            "note:\(VisionThreadRow.noChangeNote)",
            "assistant:テクノロジーを開いてください",
        ])
        let pending = rows(
            turns: [turn(.user, "デバイス別に見たい"), turn(.assistant, "テクノロジーを開いてください")],
            isLoading: false,
            sawNoChange: true
        )
        // Not loading: guidance evaluates on its own flag, so the note is
        // appended rather than inserted before an answer that has not come.
        XCTAssertEqual(texts(pending).last, "assistant:テクノロジーを開いてください")
        XCTAssertEqual(texts(pending)[1], "note:\(VisionThreadRow.noChangeNote)")
    }

    /// Row identity follows the turn, so a re-render with the same turns keeps
    /// the same rows, and two answers with the same words are still two rows.
    func testRowsAreIdentifiedByTheirTurn() {
        let a = turn(.assistant, "同じ文")
        let b = turn(.assistant, "同じ文")
        let rows = rows(turns: [a, b])
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].id, rows[1].id)
        XCTAssertEqual(rows[0].id, "assistant-\(a.id.uuidString)")
    }
}

/// The faces are one component at one size.
@MainActor
final class ThreadAvatarSizeTests: XCTestCase {
    /// The circle is exactly a one-line message tall, so a single line and its
    /// face share top and bottom edges.
    func testTheAvatarIsOneMessageLineTall() {
        let size = VisionThreadView.avatarSize(fontSize: 13)
        let font = NSFont.systemFont(ofSize: 13)
        let lineHeight = font.ascender - font.descender + font.leading
        XCTAssertEqual(size, (lineHeight + 12).rounded())
        XCTAssertGreaterThan(size, 24)
        XCTAssertLessThan(size, 34)
    }
}

/// Where the user's picture comes from.
@MainActor
final class AuthAvatarURLTests: XCTestCase {
    func testGoogleMetadataYieldsTheAvatar() {
        let metadata = [
            "avatar_url": "https://lh3.googleusercontent.com/a/x",
            "picture": "https://lh3.googleusercontent.com/a/y",
        ]
        XCTAssertEqual(
            AuthViewModel.avatarURL(in: metadata)?.absoluteString,
            "https://lh3.googleusercontent.com/a/x"
        )
        XCTAssertEqual(
            AuthViewModel.avatarURL(in: ["picture": "https://example.com/p.png"])?.host,
            "example.com"
        )
    }

    /// No picture, or one that is not a web URL, is a placeholder — never
    /// something handed to an image loader.
    func testAbsentOrUnsafeValuesAreNil() {
        XCTAssertNil(AuthViewModel.avatarURL(in: [:]))
        XCTAssertNil(AuthViewModel.avatarURL(in: ["avatar_url": ""]))
        XCTAssertNil(AuthViewModel.avatarURL(in: ["avatar_url": "file:///etc/passwd"]))
    }
}
