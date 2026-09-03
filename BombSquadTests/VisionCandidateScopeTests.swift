import XCTest
@testable import Universal_IO

/// The two rules that decide what the model is told about a screen. Both were
/// written from measurements (GA4, 26 screens, 2026-09-03; Slack, VS Code,
/// Finder and Xcode the same day), and both are wrong in a way nobody would
/// notice at runtime — one silently sends other people's bookmarks, the other
/// silently claims every control is closed — so they are fixed here.
final class VisionCandidateScopeTests: XCTestCase {

    // MARK: - What belongs to the tool

    private func candidate(_ label: String, role: String = "button") -> VisionObservation.Candidate {
        VisionObservation.Candidate(
            id: "ax:\(label.hashValue)",
            source: "ax",
            role: role,
            label: label,
            rect: CGRect(x: 0, y: 0, width: 1, height: 1),
            parentLabel: nil,
            states: []
        )
    }

    func testBrowserFurnitureIsLeftOutWhenThePageIsMeasured() {
        let found = [
            (element: candidate("戻る"), insideWebArea: false),
            (element: candidate("「https://mail.google.com/」の名前のないブックマーク"), insideWebArea: false),
            (element: candidate("レポート", role: "link"), insideWebArea: true),
            (element: candidate("管理", role: "link"), insideWebArea: true),
        ]

        let kept = VisionCandidateScope.inTool(found, sawWebArea: true)

        XCTAssertEqual(kept.map(\.label), ["レポート", "管理"])
    }

    /// A window with no page in it is a native app, and every control in it is
    /// the tool. Finder and Xcode expose no web area at all, so the filter must
    /// be inert for them rather than emptying their windows.
    func testNativeWindowKeepsEverything() {
        let found = [
            (element: candidate("新規フォルダ"), insideWebArea: false),
            (element: candidate("表示"), insideWebArea: false),
        ]

        let kept = VisionCandidateScope.inTool(found, sawWebArea: false)

        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(VisionCandidateScope.keepsChrome(sawWebArea: false))
    }

    /// Electron draws its whole interface inside the web area, so restricting to
    /// the page costs Slack and VS Code nothing. Measured: 95 of 95 and 197 of
    /// 197 candidates inside.
    func testElectronLosesNothingBecauseItIsAllPage() {
        let found = (0..<5).map { (element: candidate("項目\($0)"), insideWebArea: true) }

        XCTAssertEqual(VisionCandidateScope.inTool(found, sawWebArea: true).count, 5)
    }

    /// A browser that has not painted its page yet must not fall back to sending
    /// the toolbar instead. An empty list is already a diagnosed state; a list of
    /// bookmarks pretending to be the screen is not.
    func testAPageThatMeasuredNothingSendsNothing() {
        let found = [
            (element: candidate("再読み込み"), insideWebArea: false),
            (element: candidate("アドレス検索バー", role: "textfield"), insideWebArea: false),
        ]

        XCTAssertTrue(VisionCandidateScope.inTool(found, sawWebArea: true).isEmpty)
    }

    // MARK: - Which states say something

    func testExpandedIsWorthSaying() {
        XCTAssertEqual(
            VisionCandidateScope.expansionState(role: "AXButton", isExpanded: true),
            "expanded"
        )
    }

    /// The measurement that started this: 1,665 of 1,688 page candidates said
    /// `collapsed`, text fields included. A word every element says is not
    /// evidence about any of them.
    func testClosedIsNotWorthSayingAboutOrdinaryControls() {
        for role in ["AXButton", "AXLink", "AXPopUpButton", "AXTextField", "AXCheckBox", "AXComboBox"] {
            XCTAssertNil(
                VisionCandidateScope.expansionState(role: role, isExpanded: false),
                "\(role) should not be described as collapsed"
            )
        }
    }

    /// A disclosure triangle is the one control whose closed state is the thing
    /// the user is being asked to notice, so it keeps saying so.
    func testClosedDisclosureStillSaysSo() {
        XCTAssertEqual(
            VisionCandidateScope.expansionState(role: "AXDisclosureTriangle", isExpanded: false),
            "collapsed"
        )
        XCTAssertEqual(
            VisionCandidateScope.expansionState(role: "AXDisclosureTriangle", isExpanded: true),
            "expanded"
        )
    }
}
