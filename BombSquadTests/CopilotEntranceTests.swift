import XCTest
@testable import Universal_IO

/// Who gets offered the way into guidance.
///
/// The rule here replaced a 26-word keyword match, and the sentences below are
/// the ones that match was measured against on 2026-08-25: four of the five
/// wanted questions were rejected by the list, including the one the
/// requirement was written from. So the test that carries the requirement is
/// the first: a typed question opens the entrance whatever its wording.
@MainActor
final class CopilotEntranceTests: XCTestCase {
    /// No wording opens or closes this. If a future change makes the rule
    /// inspect the question's words again, this is where it fails.
    func testAnyTypedQuestionOpensTheEntrance() {
        let asked = [
            "ログアウトするのはどこですか?",
            "Google Analyticsでどうすれば国別のアクセス解析が見れるんですか?",
            "レポートを出力するには?",
            "請求書を発行したい",
            "国別のアクセスを見たい",
            // Not an action question, and it still gets the button. That is
            // the accepted cost of leaning toward offering: one line of the
            // bubble, against a feature nobody can reach.
            "これは何ですか?",
        ]
        for question in asked {
            XCTAssertTrue(
                VisionSession.offersGuidance(turns: [
                    turn(.user, question),
                    turn(.assistant, "この画面の説明です。"),
                ]),
                "no entrance to guidance for 「\(question)」"
            )
        }
    }

    /// Pointing asks what a thing is. It is not a request to be walked
    /// anywhere, and its turn text would become the copilot's goal.
    func testPointingAloneDoesNotOpenTheEntrance() {
        XCTAssertFalse(
            VisionSession.offersGuidance(turns: [
                turn(.user, VisionSession.pointedHereText),
                turn(.assistant, "これはヒストリーを開くボタンです。"),
            ]),
            "a tap offered to start guidance toward 「\(VisionSession.pointedHereText)」"
        )
    }

    /// Typing after a tap is still typing: the subject is now the question.
    func testAQuestionAfterPointingOpensTheEntrance() {
        XCTAssertTrue(
            VisionSession.offersGuidance(turns: [
                turn(.user, VisionSession.pointedHereText),
                turn(.assistant, "これはヒストリーを開くボタンです。"),
                turn(.user, "国別のアクセスを見たい"),
                turn(.assistant, "レポートのユーザー属性から見られます。"),
            ])
        )
    }

    /// There has to be an answer to carry into the guidance.
    func testAQuestionStillWaitingForItsAnswerDoesNotOpenTheEntrance() {
        XCTAssertFalse(
            VisionSession.offersGuidance(turns: [turn(.user, "請求書を発行したい")]),
            "the entrance appeared before the screen had been answered about"
        )
    }

    /// The opening observation has no user turn at all — `startIfNeeded` asks
    /// nothing. Offering there would put up a button whose own guard drops the
    /// press on the floor, because there is no goal to give the copilot.
    func testTheOpeningObservationDoesNotOpenTheEntrance() {
        XCTAssertFalse(
            VisionSession.offersGuidance(turns: [
                turn(.assistant, "Google Analyticsのレポート画面です。"),
            ]),
            "the entrance appeared on an observation nobody asked for"
        )
    }

    private func turn(_ role: VisionTurn.Role, _ text: String) -> VisionDisplayTurn {
        VisionDisplayTurn(role: role, text: text, mode: nil, uncertainties: [])
    }
}
