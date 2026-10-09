import CoreGraphics
import XCTest
@testable import Universal_IO

final class CompanionLiveWireTests: XCTestCase {
    // MARK: - Server messages

    func testSetupCompleteIsRecognised() {
        XCTAssertEqual(LiveEvent.parse(["setupComplete": [String: Any]()]), [.setupComplete])
    }

    func testAnInterruptionIsActedOnBeforeAudioInTheSameMessage() {
        // The interruption is about what is already queued; audio arriving
        // with it belongs to the next answer and must not be thrown away.
        let pcm = Data([1, 0, 2, 0])
        let events = LiveEvent.parse(["serverContent": [
            "interrupted": true,
            "modelTurn": ["parts": [["inlineData": [
                "mimeType": "audio/pcm;rate=24000",
                "data": pcm.base64EncodedString(),
            ]]]],
        ]])
        XCTAssertEqual(events, [.interrupted, .audio(pcm)])
    }

    func testTranscriptsAndTheTurnBoundaryArriveInOrder() {
        let events = LiveEvent.parse(["serverContent": [
            "inputTranscription": ["text": "モバイルの"],
            "outputTranscription": ["text": "はい"],
            "turnComplete": true,
        ]])
        XCTAssertEqual(events, [.heard("モバイルの"), .said("はい"), .turnComplete])
    }

    func testAToolCallCarriesItsQuestion() {
        let events = LiveEvent.parse(["toolCall": ["functionCalls": [[
            "id": "call-1",
            "name": "look_closely",
            "args": ["question": "参照元はどこ？"],
        ]]]])
        XCTAssertEqual(events, [.toolCall(LiveToolCall(id: "call-1", name: "look_closely", question: "参照元はどこ？"))])
    }

    func testOnlyAResumableHandleIsKept() {
        // While a tool call runs the server reports resumable=false; resuming
        // from that handle would lose the call.
        XCTAssertEqual(
            LiveEvent.parse(["sessionResumptionUpdate": ["newHandle": "h-1", "resumable": true]]),
            [.resumption(handle: "h-1")]
        )
        XCTAssertEqual(
            LiveEvent.parse(["sessionResumptionUpdate": ["newHandle": "h-2", "resumable": false]]),
            []
        )
    }

    func testGoAwayReadsTheProtobufDuration() {
        XCTAssertEqual(LiveEvent.parse(["goAway": ["timeLeft": "9.5s"]]), [.goAway(timeLeftMs: 9_500)])
        XCTAssertEqual(LiveEvent.parse(["goAway": [String: Any]()]), [.goAway(timeLeftMs: nil)])
    }

    func testUsageIsSplitByModality() {
        let events = LiveEvent.parse(["usageMetadata": [
            "promptTokenCount": 1_318,
            "responseTokenCount": 66,
            "totalTokenCount": 1_384,
            "thoughtsTokenCount": 77,
            "promptTokensDetails": [
                ["modality": "AUDIO", "tokenCount": 168],
                ["modality": "IMAGE", "tokenCount": 1_000],
                ["modality": "TEXT", "tokenCount": 150],
            ],
        ]])
        var expected = LiveUsage()
        expected.prompt = 1_318
        expected.response = 66
        expected.total = 1_384
        expected.thoughts = 77
        expected.promptAudio = 168
        expected.promptImage = 1_000
        expected.promptText = 150
        XCTAssertEqual(events, [.usage(expected)])
    }

    func testBinaryFramesParseLikeText() throws {
        let data = try JSONSerialization.data(withJSONObject: ["setupComplete": [String: Any]()])
        XCTAssertEqual(LiveEvent.parse(data), [.setupComplete])
        XCTAssertEqual(LiveEvent.parse(Data("not json".utf8)), [])
    }

    // MARK: - Client messages

    func testContextIsANoteAndTheGreetingIsATurn() throws {
        // A screen change sent as a turn made the POC repeat itself; only the
        // start signal asks for an answer.
        let note = try XCTUnwrap(LiveWire.note("いま前面にあるアプリ: Safari")["clientContent"] as? [String: Any])
        XCTAssertEqual(note["turnComplete"] as? Bool, false)
        let turn = try XCTUnwrap(LiveWire.turn(CompanionGreeting.start)["clientContent"] as? [String: Any])
        XCTAssertEqual(turn["turnComplete"] as? Bool, true)
    }

    func testAToolAnswerInterruptsTheBridge() throws {
        let message = LiveWire.toolResponse(id: "call-1", name: "look_closely", output: "見当たりません")
        let responses = try XCTUnwrap(
            (message["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]]
        )
        XCTAssertEqual(responses.first?["id"] as? String, "call-1")
        XCTAssertEqual(responses.first?["scheduling"] as? String, "INTERRUPT")
    }

    func testAudioIsDeclaredAt16kHz() throws {
        let audio = try XCTUnwrap(
            (LiveWire.audio(Data([0, 0]))["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any]
        )
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
    }

    func testTheTokenGoesInTheQuery() throws {
        let url = try XCTUnwrap(LiveWire.url(token: "auth_tokens/abc"))
        XCTAssertTrue(url.absoluteString.hasPrefix("wss://generativelanguage.googleapis.com/ws/"))
        XCTAssertTrue(url.absoluteString.contains("BidiGenerateContentConstrained"))
        let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first
        XCTAssertEqual(item?.name, "access_token")
        XCTAssertEqual(item?.value, "auth_tokens/abc")
    }

    // MARK: - Transcript

    func testPiecesFromOneSpeakerJoinIntoOneLine() {
        var transcript = CompanionTranscript()
        transcript.append(" モバイルの", from: .user)
        transcript.append("参照元を見たい", from: .user)
        XCTAssertEqual(transcript.lines.map(\.text), ["モバイルの参照元を見たい"])
    }

    func testAChangeOfSpeakerClosesTheLine() {
        var transcript = CompanionTranscript()
        transcript.append("こんにちは", from: .companion)
        transcript.append("どうも", from: .user)
        transcript.append("何か", from: .companion)
        XCTAssertEqual(transcript.lines.map(\.text), ["こんにちは", "どうも", "何か"])
        XCTAssertEqual(transcript.lines.map(\.isFinal), [true, true, false])
    }

    func testTheWholeConversationIsKeptForScrollingBack() {
        var transcript = CompanionTranscript()
        for index in 0..<30 {
            transcript.append("質問\(index)", from: .user)
            transcript.append("答え\(index)", from: .companion)
        }
        XCTAssertEqual(transcript.lines.count, 60)
        XCTAssertEqual(transcript.lines.first?.text, "質問0")
    }

    func testTheTurnBoundaryClosesTheLineEvenForTheSameSpeaker() {
        // `finished` never arrives on transcripts; two answers in a row must
        // not run together.
        var transcript = CompanionTranscript()
        transcript.append("一つ目", from: .companion)
        transcript.endTurn()
        transcript.append("二つ目", from: .companion)
        XCTAssertEqual(transcript.lines.map(\.text), ["一つ目", "二つ目"])
    }

    // MARK: - Screen signature

    func testTheSameScreenDoesNotCrossTheSendThreshold() throws {
        let image = try XCTUnwrap(Self.solidImage(gray: 128))
        let a = try XCTUnwrap(ScreenSignature.of(image))
        XCTAssertEqual(a.count, ScreenSignature.side * ScreenSignature.side * 3)
        XCTAssertLessThan(ScreenSignature.difference(a, a), ScreenSignature.sendThreshold)
    }

    func testAnOppositeScreenIsAsDifferentAsItGets() throws {
        let black = try XCTUnwrap(ScreenSignature.of(XCTUnwrap(Self.solidImage(gray: 0))))
        let white = try XCTUnwrap(ScreenSignature.of(XCTUnwrap(Self.solidImage(gray: 255))))
        XCTAssertEqual(ScreenSignature.difference(black, white), 1, accuracy: 0.01)
    }

    // MARK: - Greeting

    func testTheFrontAppNoteUsesThePersonasWords() {
        // The persona on the Gateway is told to listen for exactly this phrase.
        XCTAssertEqual(
            CompanionGreeting.frontAppNote(
                appName: "Google Chrome",
                windowTitle: "ホーム - Google アナリティクス",
                host: "analytics.google.com"
            ),
            "いま前面にあるアプリ: Google Chrome（ウインドウ「ホーム - Google アナリティクス」、analytics.google.com）"
        )
        XCTAssertEqual(
            CompanionGreeting.frontAppNote(appName: "Finder", windowTitle: " ", host: nil),
            "いま前面にあるアプリ: Finder"
        )
    }

    // MARK: - Turns decided on the Mac

    func testTurnsAreOpenedAndClosedWithActivityMessages() throws {
        let start = try XCTUnwrap(LiveWire.encode(LiveWire.activityStart))
        let end = try XCTUnwrap(LiveWire.encode(LiveWire.activityEnd))
        XCTAssertEqual(start, #"{"realtimeInput":{"activityStart":{}}}"#)
        XCTAssertEqual(end, #"{"realtimeInput":{"activityEnd":{}}}"#)
    }

    func testLookCloselyCarriesItsWholeRequest() {
        let events = LiveEvent.parse(["toolCall": ["functionCalls": [[
            "id": "call-2",
            "name": "look_closely",
            "args": [
                "question": "次は？",
                "goal": " モバイルの参照元を見たい ",
                "next_step": true,
                "points_at_cursor": false,
            ],
        ]]]])
        XCTAssertEqual(events, [.toolCall(LiveToolCall(
            id: "call-2", name: "look_closely", question: "次は？",
            goal: "モバイルの参照元を見たい", nextStep: true, pointsAtCursor: false
        ))])
    }

    func testAnEmptyGoalIsNoGoal() {
        let events = LiveEvent.parse(["toolCall": ["functionCalls": [[
            "id": "call-3", "name": "look_closely", "args": ["question": "これ何？", "goal": "", "points_at_cursor": true],
        ]]]])
        XCTAssertEqual(events, [.toolCall(LiveToolCall(
            id: "call-3", name: "look_closely", question: "これ何？", goal: nil, nextStep: false, pointsAtCursor: true
        ))])
    }

    func testPunctuationAloneIsNotWords() {
        XCTAssertFalse(CompanionTranscript.hasWords(" 。、?"))
        XCTAssertTrue(CompanionTranscript.hasWords("せんよ。"))
        XCTAssertTrue(CompanionTranscript.hasWords("GA4"))
    }

    func testASpacesOnlyPieceDoesNotSplitTheOtherSpeakersLine() {
        var transcript = CompanionTranscript()
        transcript.append("左の", from: .companion)
        transcript.append("  ", from: .user)
        transcript.append("メニューです", from: .companion)
        XCTAssertEqual(transcript.lines.map(\.text), ["左のメニューです"])
    }

    func testACutLineShowsWhereTheVoiceStopped() {
        var transcript = CompanionTranscript()
        transcript.append("左のメニューの", from: .companion)
        transcript.cut()
        transcript.append("はい", from: .companion)
        XCTAssertEqual(transcript.lines.map(\.text), ["左のメニューの…", "はい"])
    }

    func testTheBridgeClipsAreReadFromTheirWAVs() throws {
        var wav = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVE".utf8)
        wav += Data("fmt ".utf8) + Data([16, 0, 0, 0])
        wav += Data([1, 0, 1, 0]) + Data([0xC0, 0x5D, 0, 0]) + Data([0x80, 0xBB, 0, 0]) + Data([2, 0, 16, 0])
        wav += Data("data".utf8) + Data([4, 0, 0, 0]) + Data([1, 0, 2, 0])
        XCTAssertEqual(CompanionBridge.pcm16(fromWAV: wav), Data([1, 0, 2, 0]))
        // 44.1 kHz is not what the player expects.
        var other = wav
        other.replaceSubrange(24..<28, with: Data([0x44, 0xAC, 0, 0]))
        XCTAssertNil(CompanionBridge.pcm16(fromWAV: other))
    }

    private static func solidImage(gray: UInt8) -> CGImage? {
        let side = 32
        var pixels = [UInt8](repeating: gray, count: side * side * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side, height: side,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
