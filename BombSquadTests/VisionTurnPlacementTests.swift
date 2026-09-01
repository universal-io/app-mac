import XCTest
@testable import Universal_IO

/// A pointing gesture owns exactly one placement decision.
///
/// These tests pin the ordering contract independently of SwiftUI and the
/// overlay: an unresolved gesture cannot expose words, and neither a late
/// model box nor a second callback can revise a committed placement.
final class VisionTurnPlacementTests: XCTestCase {
    func testUnresolvedGestureBuffersUntilAnswerPlacementCommits() {
        var placement = VisionTurnPlacementState()

        placement.begin()

        XCTAssertEqual(placement.phase, .resolving)
        XCTAssertTrue(placement.buffersStreamedContent)
        XCTAssertTrue(placement.allowsAnswerPlacementCommit)

        XCTAssertTrue(placement.commit(.answer))
        XCTAssertEqual(placement.phase, .committed(.answer))
        XCTAssertFalse(placement.buffersStreamedContent)
        XCTAssertFalse(placement.allowsAnswerPlacementCommit)
    }

    func testMeasuredElementCommitsBeforeContentCanStream() {
        var placement = VisionTurnPlacementState()

        placement.begin()
        XCTAssertTrue(placement.commit(.measured))

        XCTAssertFalse(placement.buffersStreamedContent)
        placement.contentBecameVisible()
        XCTAssertEqual(placement.phase, .contentVisible(.measured))
    }

    func testEnclosedRegionIsACommittedLocalPlacement() {
        var placement = VisionTurnPlacementState()

        placement.begin()
        XCTAssertTrue(placement.commit(.region))
        placement.contentBecameVisible()

        XCTAssertEqual(placement.phase, .contentVisible(.region))
        XCTAssertFalse(placement.allowsAnswerPlacementCommit)
    }

    func testUnavailableGeometryStillSettlesBeforeAnswerAppears() {
        var placement = VisionTurnPlacementState()

        placement.begin()
        XCTAssertTrue(placement.commit(.unavailable))
        placement.contentBecameVisible()

        XCTAssertEqual(placement.phase, .contentVisible(.unavailable))
        XCTAssertFalse(placement.buffersStreamedContent)
    }

    func testCommittedPlacementCannotBeRevised() {
        var placement = VisionTurnPlacementState()

        placement.begin()
        XCTAssertTrue(placement.commit(.measured))
        XCTAssertFalse(placement.commit(.answer))
        placement.contentBecameVisible()
        XCTAssertFalse(placement.commit(.unavailable))

        XCTAssertEqual(placement.phase, .contentVisible(.measured))
    }

    func testResetReturnsNonPointingTurnsToOrdinaryStreaming() {
        var placement = VisionTurnPlacementState()
        placement.begin()
        XCTAssertTrue(placement.buffersStreamedContent)

        placement.reset()

        XCTAssertEqual(placement.phase, .inactive)
        XCTAssertFalse(placement.buffersStreamedContent)
        XCTAssertFalse(placement.allowsAnswerPlacementCommit)
    }
}
