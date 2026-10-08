import XCTest
@testable import Universal_IO

/// R18 V2: what the eye hands the voice model, and what it asks the reader.
///
/// The voice may name only what a look gave it, so the three-line tool output
/// and the visible list are its whole vocabulary about the screen. What the
/// request carries — question or guidance, the voice note, the history — is
/// pinned here because the route refuses a wrong shape outright.
@MainActor
final class CompanionEyeTests: XCTestCase {
    private typealias Look = CompanionEye.Look
    private typealias Line = CompanionEye.Line

    /// 12:34:56 UTC.
    private let fixedDate = Date(timeIntervalSince1970: 45_296)
    private let utc = TimeZone(secondsFromGMT: 0) ?? .current

    // MARK: - The tool output

    func testAStepWithAMeasuredMarkNamesTheControl() {
        let look = Look(
            kind: .nextStep,
            message: "左のメニューの「レポート」を押してください。",
            markedLabel: "レポート",
            marked: true,
            skillName: "Google アナリティクス",
            elapsedMs: 4_200
        )
        XCTAssertEqual(
            look.toolOutput,
            "言うこと: 左のメニューの「レポート」を押してください。\n種類: 次の一歩\n印: 出した（「レポート」）"
        )
    }

    /// The model's own box marks a place but measures no control, so there
    /// is no name to give.
    func testAMarkFromTheModelsOwnBoxCarriesNoName() {
        let look = Look(
            kind: .answer, message: "これは期間の選択欄です。", markedLabel: nil,
            marked: true, skillName: nil, elapsedMs: 3_900
        )
        XCTAssertEqual(look.toolOutput, "言うこと: これは期間の選択欄です。\n種類: 答え\n印: 出した")
    }

    func testNoMarkSaysNone() {
        let look = Look(
            kind: .consult, message: "ログインが必要です。続けますか？", markedLabel: nil,
            marked: false, skillName: nil, elapsedMs: 5_000
        )
        XCTAssertEqual(look.toolOutput, "言うこと: ログインが必要です。続けますか？\n種類: 相談\n印: なし")
    }

    func testAFailureHasNothingToSay() {
        XCTAssertEqual(Look.failure(elapsedMs: 15_000).toolOutput, "言うこと: なし\n種類: 失敗\n印: なし")
    }

    func testEveryKindHasItsWord() {
        let words: [(Look.Kind, String)] = [
            (.nextStep, "次の一歩"), (.answer, "答え"), (.done, "完了"),
            (.consult, "相談"), (.observation, "画面の説明"), (.failure, "失敗"),
        ]
        for (kind, word) in words {
            let look = Look(kind: kind, message: "x", markedLabel: nil, marked: false, skillName: nil, elapsedMs: 0)
            XCTAssertEqual(look.toolOutput.components(separatedBy: "\n")[1], "種類: \(word)")
        }
    }

    /// Three lines is the contract the persona reads. A label with a line
    /// break in it, which AX allows, must not add a fourth.
    func testTheOutputStaysThreeLinesWhateverItCarries() {
        let look = Look(
            kind: .nextStep, message: "一行目\n二行目", markedLabel: "保存して\n閉じる",
            marked: true, skillName: nil, elapsedMs: 0
        )
        let lines = look.toolOutput.components(separatedBy: "\n")
        XCTAssertEqual(lines, ["言うこと: 一行目 二行目", "種類: 次の一歩", "印: 出した（「保存して 閉じる」）"])
    }

    // MARK: - What kind of answer

    func testKindsFollowTheModeAndWhetherItWasGuidance() {
        XCTAssertEqual(CompanionEye.kind(for: .guide, guidance: false), .nextStep)
        XCTAssertEqual(CompanionEye.kind(for: .guide, guidance: true), .nextStep)
        XCTAssertEqual(CompanionEye.kind(for: .answer, guidance: false), .answer)
        // In guidance an answer is the goal reached.
        XCTAssertEqual(CompanionEye.kind(for: .answer, guidance: true), .done)
        XCTAssertEqual(CompanionEye.kind(for: .clarification, guidance: true), .consult)
        XCTAssertEqual(CompanionEye.kind(for: .clarification, guidance: false), .consult)
        XCTAssertEqual(CompanionEye.kind(for: .observation, guidance: false), .observation)
    }

    // MARK: - The message

    func testTheMessageBecomesOneLine() {
        XCTAssertEqual(
            CompanionEye.spokenMessage("左のメニューから「レポート」を開きます。\n次に、右上の「エクスポート」を押してください。\n"),
            "左のメニューから「レポート」を開きます。次に、右上の「エクスポート」を押してください。"
        )
    }

    func testMarkdownComesOffAndNamesStay() {
        XCTAssertEqual(
            CompanionEye.spokenMessage("## 手順:\n1. **「レポート」**を開く\n2. `エクスポート`を押す"),
            "手順:「レポート」を開く エクスポートを押す"
        )
        XCTAssertEqual(CompanionEye.spokenMessage("・「保存」を押します。"), "「保存」を押します。")
        XCTAssertEqual(
            CompanionEye.spokenMessage("Open **Reports**.\nThen click [Export](https://example.com/x)."),
            "Open Reports. Then click Export."
        )
    }

    /// A number at the start of a sentence is not a list marker.
    func testANumberIsNotTakenForAListMarker() {
        XCTAssertEqual(CompanionEye.spokenMessage("1.5倍に拡大されています。"), "1.5倍に拡大されています。")
    }

    // MARK: - The question

    func testAQuestionCarriesTheVoiceNoteOnALineOfItsOwn() {
        let plan = CompanionEye.plan(request(question: " 保存はどこ？ "))
        XCTAssertEqual(plan.question, "保存はどこ？\n" + CompanionEye.voiceNote)
        XCTAssertNil(plan.guidance)
    }

    func testTheVoiceNoteAsksForWhatTheVoiceNeeds() {
        XCTAssertEqual(
            CompanionEye.voiceNote,
            "（この答えは音声で読み上げます。1〜2文で、ボタンやメニューの名前は画面の文言どおり「」で囲み、"
                + "場所（左のメニュー、右上など）を添えてください。聞かれたものがこの画面に見えないときは"
                + "「この画面には見当たりません。」で始め、見えているものから次に開く候補を1つだけ挙げてください。）"
        )
    }

    /// The route refuses a question and guidance together; a next step sends
    /// guidance alone, and no pointer.
    func testANextStepContinuesGuidanceInsteadOfAsking() {
        let plan = CompanionEye.plan(request(
            question: "次は？",
            goal: "国別のアクセスを見たい",
            nextStep: true,
            pointsAtCursor: true,
            previousInstruction: "左の「レポート」を押してください。"
        ))
        XCTAssertNil(plan.question)
        XCTAssertEqual(
            plan.guidance,
            ScreenGuidanceContext(goal: "国別のアクセスを見たい", previousInstruction: "左の「レポート」を押してください。")
        )
        XCTAssertFalse(plan.pointsAtCursor)
    }

    func testTheQuestionStandsInForAMissingGoal() {
        for goal in [nil, "", "  "] as [String?] {
            let plan = CompanionEye.plan(request(
                question: "国別のアクセスはどこで見られますか",
                goal: goal,
                nextStep: true,
                previousInstruction: "左の「レポート」を押してください。"
            ))
            XCTAssertEqual(plan.guidance?.goal, "国別のアクセスはどこで見られますか")
            XCTAssertNil(plan.question)
        }
    }

    /// Guidance needs the instruction it continues from; without one the look
    /// is asked as a question, which still reads the screen.
    func testANextStepWithNothingToContinueFromIsAskedAsAQuestion() {
        for previous in [nil, "", " \n"] as [String?] {
            let plan = CompanionEye.plan(request(question: "次は？", nextStep: true, previousInstruction: previous))
            XCTAssertNil(plan.guidance)
            XCTAssertEqual(plan.question, "次は？\n" + CompanionEye.voiceNote)
        }
    }

    func testAWordlessLookAsksForTheScreen() {
        let plan = CompanionEye.plan(request(question: "  ", pointsAtCursor: true))
        XCTAssertNil(plan.question)
        XCTAssertNil(plan.guidance)
        XCTAssertTrue(plan.pointsAtCursor)
    }

    func testALongQuestionIsCutToTheGatewayLimit() {
        let sent = CompanionEye.plan(request(question: String(repeating: "あ", count: 5_000))).question ?? ""
        XCTAssertEqual(sent.utf16.count, CompanionEye.maxFieldCharacters)
        XCTAssertTrue(sent.hasSuffix("\n" + CompanionEye.voiceNote))
    }

    /// The route counts UTF-16; the cut never splits a character.
    func testTheCutFallsBetweenCharacters() {
        XCTAssertEqual(CompanionEye.clipped("😀😀", toUTF16: 3), "😀")
        XCTAssertEqual(CompanionEye.clipped("abc", toUTF16: 3), "abc")
    }

    // MARK: - The conversation

    func testTheConversationTravelsAsTheLastTwelveTurns() {
        let lines = (0..<15).map { index in
            Line(role: index.isMultiple(of: 2) ? .user : .companion, text: "line \(index)")
        }
        let turns = CompanionEye.wireTurns(lines)
        XCTAssertEqual(turns.count, CompanionEye.historyTurns)
        XCTAssertEqual(turns.first, VisionTurn(role: .assistant, text: "line 3"))
        XCTAssertEqual(turns.last, VisionTurn(role: .user, text: "line 14"))
    }

    func testEmptyLinesDoNotTravel() {
        let turns = CompanionEye.wireTurns([
            Line(role: .user, text: "  "),
            Line(role: .companion, text: "「保存」を押してください。"),
        ])
        XCTAssertEqual(turns, [VisionTurn(role: .assistant, text: "「保存」を押してください。")])
    }

    // MARK: - What travels with the candidates

    /// `window_off_capture` is the walk's own reason and the route's list
    /// predates it: sending it would fail the whole look with 400.
    func testAReasonTheGatewayRefusesKeepsTheDiagnosticsHome() {
        XCTAssertNil(CompanionEye.wireDiagnostics(diagnostics("window_off_capture")))
        XCTAssertNotNil(CompanionEye.wireDiagnostics(diagnostics(nil)))
        XCTAssertNotNil(CompanionEye.wireDiagnostics(diagnostics("deadline")))
        XCTAssertNotNil(CompanionEye.wireDiagnostics(diagnostics("no_target_app")))
    }

    /// Main display 1000×800, captured whole. Cocoa (250, 600) is CG (250, 200).
    func testThePointerIsWhereTheCursorIsInTheCapture() {
        let save = candidate("ax:1", role: "button", label: "保存", rect: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1))
        let toolbar = candidate("ax:0", role: "button", label: "ツールバー", rect: CGRect(x: 0, y: 0, width: 1, height: 0.4))
        let pointer = CompanionEye.pointer(
            atCocoa: CGPoint(x: 250, y: 600),
            mainDisplayHeight: 800,
            captureRect: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            candidates: [toolbar, save]
        )
        XCTAssertEqual(pointer?.kind, .point(CGPoint(x: 0.25, y: 0.25)))
        XCTAssertEqual(pointer?.hitCandidateID, "ax:1")
    }

    func testACursorOnAnotherDisplaySendsNoPointer() {
        XCTAssertNil(CompanionEye.pointer(
            atCocoa: CGPoint(x: 1_500, y: 400),
            mainDisplayHeight: 800,
            captureRect: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            candidates: []
        ))
    }

    // MARK: - The visible list

    func testTheListReadsTopToBottomThenLeftToRight() {
        let list = CompanionEye.visibleListText([
            candidate("ax:3", role: "button", label: "共有", rect: CGRect(x: 0.85, y: 0.02, width: 0.05, height: 0.03)),
            candidate("ax:1", role: "button", label: "保存", rect: CGRect(x: 0.05, y: 0.021, width: 0.05, height: 0.03)),
            candidate("ax:4", role: "textfield", label: "検索", rect: CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.04)),
            candidate("ax:2", role: "link", label: "レポート", rect: CGRect(x: 0.02, y: 0.4, width: 0.15, height: 0.03)),
        ], at: fixedDate, timeZone: utc)
        XCTAssertEqual(list, """
        いま見えている要素（アプリが取得、12:34:56）:
        - 左上 ボタン「保存」
        - 右上 ボタン「共有」
        - 左 リンク「レポート」
        - 中央 入力欄「検索」
        """)
    }

    func testPlaceWordsDivideTheScreenInThirds() {
        let cases: [(x: CGFloat, y: CGFloat, word: String)] = [
            (0.1, 0.1, "左上"), (0.5, 0.1, "上"), (0.9, 0.1, "右上"),
            (0.1, 0.5, "左"), (0.5, 0.5, "中央"), (0.9, 0.5, "右"),
            (0.1, 0.9, "左下"), (0.5, 0.9, "下"), (0.9, 0.9, "右下"),
        ]
        for place in cases {
            let rect = CGRect(x: place.x - 0.01, y: place.y - 0.01, width: 0.02, height: 0.02)
            XCTAssertEqual(CompanionEye.placeWord(rect), place.word, "\(place.x), \(place.y)")
        }
    }

    /// The collector writes roles lowercased without "AX".
    func testRoleWordsCoverWhatTheCollectorWrites() {
        let cases: [(String?, String)] = [
            ("button", "ボタン"), ("link", "リンク"), ("tab", "タブ"),
            ("menuitem", "メニュー"), ("menubutton", "メニュー"), ("AXMenuItem", "メニュー"),
            ("textfield", "入力欄"), ("searchfield", "入力欄"), ("textarea", "入力欄"),
            ("checkbox", "チェックボックス"), ("radiobutton", "ラジオボタン"),
            ("popupbutton", "選択欄"), ("combobox", "選択欄"),
            ("heading", "見出し"), ("statictext", "文字"),
            ("disclosuretriangle", "要素"), (nil, "要素"),
        ]
        for (role, word) in cases {
            XCTAssertEqual(CompanionEye.roleWord(role), word, role ?? "nil")
        }
    }

    func testStatesAPersonWouldMention() {
        let list = CompanionEye.visibleListText([
            candidate("ax:1", role: "tab", label: "レポート", rect: row(0), states: ["focused", "selected"]),
            candidate("ax:2", role: "button", label: "送信", rect: row(1), states: ["disabled"]),
            candidate("ax:3", role: "checkbox", label: "保存する", rect: row(2), states: ["checked"]),
            candidate("ax:4", role: "button", label: "詳細", rect: row(3), states: ["expanded"]),
            candidate("ax:5", role: "checkbox", label: "通知", rect: row(4), states: ["unchecked"]),
        ], at: fixedDate, timeZone: utc)
        XCTAssertEqual(list?.components(separatedBy: "\n").dropFirst(), [
            "- 左上 タブ「レポート」（選択中）",
            "- 左上 ボタン「送信」（無効）",
            "- 左上 チェックボックス「保存する」（オン）",
            "- 左上 ボタン「詳細」（開いている）",
            "- 左上 チェックボックス「通知」",
        ])
        XCTAssertEqual(CompanionEye.stateWords(["disabled", "selected", "disabled"]), ["無効", "選択中"])
    }

    func testTheSameControlIsListedOnce() {
        let list = CompanionEye.visibleListText(
            (0..<3).map { candidate("ax:\($0)", role: "button", label: "削除", rect: row($0)) },
            at: fixedDate,
            timeZone: utc
        )
        XCTAssertEqual(list?.components(separatedBy: "\n").count, 2)
    }

    func testTheListStopsAtSixty() {
        let list = CompanionEye.visibleListText(
            (0..<80).map { candidate("ax:\($0)", role: "link", label: "項目\($0)", rect: row($0 % 20)) },
            at: fixedDate,
            timeZone: utc
        )
        XCTAssertEqual(list?.components(separatedBy: "\n").count, CompanionEye.visibleListLimit + 1)
    }

    func testLongLabelsAreCutAndKeptOnOneLine() {
        let long = String(repeating: "長", count: 50)
        let list = CompanionEye.visibleListText([
            candidate("ax:1", role: "button", label: "保存して\n閉じる", rect: row(0)),
            candidate("ax:2", role: "statictext", label: long, rect: row(1)),
        ], at: fixedDate, timeZone: utc)
        XCTAssertEqual(list?.components(separatedBy: "\n").dropFirst(), [
            "- 左上 ボタン「保存して 閉じる」",
            "- 左上 文字「\(String(repeating: "長", count: CompanionEye.visibleLabelLimit))…」",
        ])
    }

    func testNothingToListIsNil() {
        XCTAssertNil(CompanionEye.visibleListText([], at: fixedDate, timeZone: utc))
    }

    // MARK: - The mark follows its element

    /// Sub-point jitter between two AX reads is the same place; a move the
    /// eye can see is not.
    func testJitterIsNotAMove() {
        let capture = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let shown = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.05)
        XCTAssertTrue(CompanionEye.isSamePlace(shown, shown.offsetBy(dx: 0.0002, dy: 0), in: capture))
        XCTAssertFalse(CompanionEye.isSamePlace(shown, shown.offsetBy(dx: 0, dy: 0.01), in: capture))
        XCTAssertFalse(CompanionEye.isSamePlace(shown, nil, in: capture))
        XCTAssertTrue(CompanionEye.isSamePlace(nil, nil, in: capture))
    }

    // MARK: - The guide's valve

    func testGuidanceEndsWhenTheGoalIsReachedOrAtTheStepLimit() {
        XCTAssertEqual(CompanionGuide.ending(after: .done, steps: 1), .done)
        XCTAssertEqual(CompanionGuide.ending(after: .nextStep, steps: CompanionGuide.maxSteps), .stepLimit)
        XCTAssertNil(CompanionGuide.ending(after: .nextStep, steps: CompanionGuide.maxSteps - 1))
        XCTAssertNil(CompanionGuide.ending(after: .consult, steps: 3))
        XCTAssertNil(CompanionGuide.ending(after: .failure, steps: 3))
    }

    // MARK: - Helpers

    private func request(
        question: String,
        goal: String? = nil,
        nextStep: Bool = false,
        pointsAtCursor: Bool = false,
        previousInstruction: String? = nil
    ) -> CompanionEye.Request {
        CompanionEye.Request(
            question: question,
            goal: goal,
            nextStep: nextStep,
            pointsAtCursor: pointsAtCursor,
            history: [],
            previousInstruction: previousInstruction,
            displayID: nil
        )
    }

    private func candidate(
        _ id: String,
        role: String?,
        label: String,
        rect: CGRect?,
        states: [String] = []
    ) -> VisionObservation.Candidate {
        VisionObservation.Candidate(
            id: id, source: "ax", role: role, label: label,
            rect: rect, parentLabel: nil, states: states
        )
    }

    /// One row per index, down the left edge of the top third.
    private func row(_ index: Int) -> CGRect {
        CGRect(x: 0.02, y: 0.01 + CGFloat(index) * 0.015, width: 0.1, height: 0.01)
    }

    private func diagnostics(_ reason: String?) -> VisionObservationCaptureService.Diagnostics {
        VisionObservationCaptureService.Diagnostics(
            elapsedMs: 900,
            visitedNodes: 1_700,
            candidateCount: 0,
            truncatedReason: reason
        )
    }
}
