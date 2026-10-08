import XCTest
@testable import Universal_IO

final class CompanionTurnTakerTests: XCTestCase {
    /// One tap block: 1024 frames at 48 kHz.
    private let block: TimeInterval = 1_024.0 / 48_000

    private struct Run {
        var events: [CompanionTurnTaker.Event] = []
        var end: TimeInterval = 0
        var started: CompanionTurnTaker.Event? {
            events.first { if case .started = $0 { return true } else { return false } }
        }
        var stopped: CompanionTurnTaker.Event? {
            events.first { if case .stopped = $0 { return true } else { return false } }
        }
        func time(of wanted: CompanionTurnTaker.Event, from start: TimeInterval, block: TimeInterval) -> TimeInterval? {
            events.firstIndex(of: wanted).map { start + Double($0) * block }
        }
    }

    /// Feeds `seconds` of a constant level.
    private func feed(
        _ taker: inout CompanionTurnTaker,
        levelDb: Float,
        seconds: TimeInterval,
        from start: TimeInterval,
        voice: CompanionTurnTaker.Voice = .ended(at: -100)
    ) -> Run {
        var run = Run()
        var now = start
        while now < start + seconds - 1e-9 {
            run.events.append(taker.process(levelDb: levelDb, duration: block, now: now, voice: voice))
            now += block
        }
        run.end = now
        return run
    }

    // MARK: - Nothing playing

    func testAQuietRoomStartsNothing() {
        var taker = CompanionTurnTaker()
        let run = feed(&taker, levelDb: -58, seconds: 3, from: 0)
        XCTAssertTrue(run.events.allSatisfy { $0 == .none })
        XCTAssertEqual(taker.floorDb ?? 0, -58, accuracy: 0.5)
    }

    func testSpeechStartsATurnWithinAQuarterSecondAndKeepsItsStart() {
        var taker = CompanionTurnTaker()
        let room = feed(&taker, levelDb: -58, seconds: 2, from: 0)
        let speech = feed(&taker, levelDb: -30, seconds: 0.5, from: room.end)
        guard case .started(let overVoice, let since)? = speech.started,
              let index = speech.events.firstIndex(where: { $0 != .none })
        else { return XCTFail("no start") }
        XCTAssertFalse(overVoice)
        XCTAssertLessThanOrEqual(Double(index) * block, 0.25)
        // The pre-roll reaches back before the first block that counted.
        XCTAssertLessThan(since, room.end)
        XCTAssertGreaterThanOrEqual(since, room.end - 0.11)
        XCTAssertTrue(taker.userSpeaking)
    }

    func testAKeyPressIsNotAVoice() {
        var taker = CompanionTurnTaker()
        var now = feed(&taker, levelDb: -58, seconds: 2, from: 0).end
        for _ in 0..<6 {
            let press = feed(&taker, levelDb: -25, seconds: 0.05, from: now)
            XCTAssertNil(press.started)
            now = feed(&taker, levelDb: -58, seconds: 0.25, from: press.end).end
        }
    }

    func testAMidSentencePauseDoesNotEndTheTurn() {
        // 「モバイルの参照元を見たいんですけど、」…「どこを開けばいいですか」
        var taker = CompanionTurnTaker()
        var now = feed(&taker, levelDb: -58, seconds: 1, from: 0).end
        now = feed(&taker, levelDb: -30, seconds: 1.5, from: now).end
        let pause = feed(&taker, levelDb: -58, seconds: 0.5, from: now)
        XCTAssertNil(pause.stopped)
        now = feed(&taker, levelDb: -30, seconds: 1, from: pause.end).end
        let end = feed(&taker, levelDb: -58, seconds: 1, from: now)
        guard let stopIndex = end.events.firstIndex(of: .stopped(.silence)) else { return XCTFail("no stop") }
        XCTAssertEqual(Double(stopIndex + 1) * block, taker.settings.endSilence, accuracy: block * 1.5)
        XCTAssertFalse(taker.userSpeaking)
    }

    func testAVeryLongTurnIsCut() {
        // Speech dips between words, so the floor stays where the room is and
        // only the length limit ends it.
        var taker = CompanionTurnTaker()
        var now = feed(&taker, levelDb: -58, seconds: 1, from: 0).end
        var events: [CompanionTurnTaker.Event] = []
        while now < 33 {
            let words = feed(&taker, levelDb: -30, seconds: 0.3, from: now)
            let dip = feed(&taker, levelDb: -58, seconds: 0.1, from: words.end)
            events += words.events + dip.events
            now = dip.end
        }
        XCTAssertTrue(events.contains(.stopped(.maxLength)))
        XCTAssertFalse(events.contains(.stopped(.silence)))
    }

    func testASteadySoundBecomesTheRoomInsteadOfAnEndlessTurn() {
        // Music or a fan that starts and stays: within seconds it is the room,
        // the turn it opened ends, and it opens no other.
        var taker = CompanionTurnTaker()
        let room = feed(&taker, levelDb: -60, seconds: 2, from: 0)
        let music = feed(&taker, levelDb: -40, seconds: 20, from: room.end)
        guard let stop = music.events.firstIndex(of: .stopped(.silence)) else { return XCTFail("no stop") }
        XCTAssertLessThan(Double(stop) * block, 15)
        XCTAssertFalse(music.events.suffix(from: stop + 1).contains { if case .started = $0 { return true } else { return false } })
        XCTAssertEqual(taker.floorDb ?? 0, -40, accuracy: 1)
    }

    func testDigitalSilenceIsNotTheRoom() {
        var taker = CompanionTurnTaker()
        _ = feed(&taker, levelDb: -120, seconds: 0.5, from: 0)
        XCTAssertNil(taker.floorDb)
        _ = feed(&taker, levelDb: -62, seconds: 0.5, from: 0.5)
        XCTAssertEqual(taker.floorDb ?? 0, -62, accuracy: 0.5)
    }

    func testTheLineHasAMinimumInADeadQuietRoom() {
        var taker = CompanionTurnTaker()
        _ = feed(&taker, levelDb: -90, seconds: 1, from: 0)
        XCTAssertEqual(taker.line(voiceInRoom: false) ?? 0, taker.settings.startMinimumDb, accuracy: 0.01)
    }

    // MARK: - Over the companion's voice

    func testTheCompanionsOwnEchoNeverStartsATurn() {
        // Build 19 on the speakers: the echo sat 12–15 dB above the floor.
        var taker = CompanionTurnTaker()
        let room = feed(&taker, levelDb: -55, seconds: 1, from: 0)
        let voice = feed(&taker, levelDb: -40, seconds: 8, from: room.end, voice: .playing)
        XCTAssertTrue(voice.events.allSatisfy { $0 == .none })
        XCTAssertEqual(taker.echoDb ?? 0, -40, accuracy: 0.5)
        // Nor does its tail.
        let tail = feed(&taker, levelDb: -42, seconds: 0.35, from: voice.end, voice: .ended(at: voice.end))
        XCTAssertTrue(tail.events.allSatisfy { $0 == .none })
    }

    func testEchoPeaksAsLongAsASyllableDoNotCount() {
        var taker = CompanionTurnTaker()
        var now = feed(&taker, levelDb: -40, seconds: 2, from: 0, voice: .playing).end
        for _ in 0..<5 {
            let peak = feed(&taker, levelDb: -28, seconds: 0.12, from: now, voice: .playing)
            XCTAssertNil(peak.started)
            now = feed(&taker, levelDb: -40, seconds: 0.4, from: peak.end, voice: .playing).end
        }
    }

    func testAPersonTalkingOverTheVoiceStartsATurn() {
        var taker = CompanionTurnTaker()
        let echo = feed(&taker, levelDb: -40, seconds: 2, from: 0, voice: .playing)
        let over = feed(&taker, levelDb: -24, seconds: 0.4, from: echo.end, voice: .playing)
        guard case .started(let overVoice, _)? = over.started else { return XCTFail("no start") }
        XCTAssertTrue(overVoice)
        XCTAssertTrue(taker.utterance.overVoice)
    }

    func testClicksAreNotAVoiceEvenWhenTheEchoIsGone() {
        // Build 20: echo cancelled to about −86 dBFS, the room at −76, clicks
        // averaging −60 with peaks of −50. None of it is a person.
        var taker = CompanionTurnTaker()
        let room = feed(&taker, levelDb: -76, seconds: 1, from: 0)
        var now = feed(&taker, levelDb: -86, seconds: 2, from: room.end, voice: .playing).end
        for _ in 0..<4 {
            let click = feed(&taker, levelDb: -50, seconds: 0.3, from: now, voice: .playing)
            XCTAssertNil(click.started)
            now = feed(&taker, levelDb: -86, seconds: 0.3, from: click.end, voice: .playing).end
        }
        let idleClick = feed(&taker, levelDb: -50, seconds: 0.4, from: now, voice: .ended(at: now - 5))
        XCTAssertNil(idleClick.started)
    }

    func testNothingCountsOverTheVoiceBeforeItsEchoIsKnown() {
        // The greeting's first words: however loud, they are not a person yet.
        var taker = CompanionTurnTaker()
        let early = feed(&taker, levelDb: -20, seconds: 0.45, from: 0, voice: .playing)
        XCTAssertNil(early.started)
        XCTAssertNil(taker.line(voiceInRoom: true))
    }

    func testAPausedVoiceLeavesTheRoomAtOnce() {
        var taker = CompanionTurnTaker()
        _ = feed(&taker, levelDb: -40, seconds: 2, from: 0, voice: .playing)
        XCTAssertEqual(
            taker.line(voiceInRoom: false) ?? 0,
            max(taker.settings.startMinimumDb, (taker.floorDb ?? taker.settings.assumedFloorDb) + taker.settings.startMarginDb),
            accuracy: 0.01
        )
        let run = feed(&taker, levelDb: -30, seconds: 0.4, from: 2, voice: .paused)
        guard case .started(let overVoice, _)? = run.started else { return XCTFail("no start") }
        XCTAssertFalse(overVoice)
    }

    func testTheEchoIsNotTakenForTheFloor() {
        var taker = CompanionTurnTaker()
        _ = feed(&taker, levelDb: -58, seconds: 1, from: 0)
        _ = feed(&taker, levelDb: -40, seconds: 3, from: 1, voice: .playing)
        XCTAssertEqual(taker.floorDb ?? 0, -58, accuracy: 0.5)
    }

    func testMutingEndsATurnInProgress() {
        var taker = CompanionTurnTaker()
        let now = feed(&taker, levelDb: -58, seconds: 1, from: 0).end
        _ = feed(&taker, levelDb: -30, seconds: 0.5, from: now)
        XCTAssertTrue(taker.forceStop())
        XCTAssertFalse(taker.userSpeaking)
        XCTAssertFalse(taker.forceStop())
    }
}
