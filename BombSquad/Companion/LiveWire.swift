import CoreGraphics
import Foundation

/// R18: the Gemini Live wire as plain values. The socket moves bytes and the
/// session decides what they mean; this file is the only place that knows the
/// JSON field names. The Gateway's `/ai/live-token` locks the setup; the rest
/// of the shapes are the ones the web POC ran on (app-web
/// `docs/voice-companion-native.md`).
enum LiveWire {
    static let endpoint = "wss://generativelanguage.googleapis.com/ws/"
        + "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"

    static func url(token: String) -> URL? {
        var components = URLComponents(string: endpoint)
        components?.queryItems = [URLQueryItem(name: "access_token", value: token)]
        return components?.url
    }

    // MARK: - Client to server

    static func setup(_ setup: [String: Any]) -> [String: Any] {
        ["setup": setup]
    }

    /// 16 kHz mono PCM16 little-endian.
    static func audio(_ pcm16: Data) -> [String: Any] {
        ["realtimeInput": ["audio": [
            "data": pcm16.base64EncodedString(),
            "mimeType": "audio/pcm;rate=16000",
        ]]]
    }

    /// The user started talking. Sessions are opened with the server's own
    /// turn detection off (`CompanionTurnTaker`): only audio between this and
    /// `activityEnd` is the user's turn, and this interrupts any answer.
    static let activityStart: [String: Any] = ["realtimeInput": ["activityStart": [String: Any]()]]

    /// The user stopped talking: the model answers now.
    static let activityEnd: [String: Any] = ["realtimeInput": ["activityEnd": [String: Any]()]]

    static func video(jpeg: Data) -> [String: Any] {
        ["realtimeInput": ["video": [
            "data": jpeg.base64EncodedString(),
            "mimeType": "image/jpeg",
        ]]]
    }

    /// Something the model should know but not answer. A screen change sent
    /// as a turn made the POC repeat its last instruction like a broken
    /// record, so context always goes this way. Sent mid-answer or mid-turn it
    /// interrupts nothing (probed against gemini-3.8-live, 2026-10-08).
    static func note(_ text: String) -> [String: Any] {
        content(text, turnComplete: false)
    }

    /// A turn: the model answers it.
    static func turn(_ text: String) -> [String: Any] {
        content(text, turnComplete: true)
    }

    /// When the model takes a tool's result in: INTERRUPT speaks it at once,
    /// even over the bridge phrase; SILENT only adds it to the context (a
    /// look a newer one overtook, whose answer would contradict it).
    enum Scheduling: String {
        case interrupt = "INTERRUPT"
        case silent = "SILENT"
    }

    static func toolResponse(
        id: String,
        name: String,
        output: String,
        scheduling: Scheduling = .interrupt
    ) -> [String: Any] {
        ["toolResponse": ["functionResponses": [[
            "id": id,
            "name": name,
            "response": ["output": output],
            "scheduling": scheduling.rawValue,
        ]]]]
    }

    static func encode(_ message: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func content(_ text: String, turnComplete: Bool) -> [String: Any] {
        ["clientContent": [
            "turns": [["role": "user", "parts": [["text": text]]]],
            "turnComplete": turnComplete,
        ]]
    }
}

struct LiveToolCall: Equatable {
    let id: String
    let name: String
    let question: String?
    /// look_closely's other arguments (Gateway live-session.ts).
    var goal: String?
    var nextStep = false
    var pointsAtCursor = false
}

/// Token counts only. Whether the bill is "every turn re-reads the whole
/// context" or "only what was streamed" is still open (requirements R19), and
/// these are what settle it against the invoice.
struct LiveUsage: Equatable {
    var prompt = 0
    var response = 0
    var total = 0
    var thoughts = 0
    var promptAudio = 0
    var promptImage = 0
    var promptText = 0
}

/// What one server message says, in the order it should be acted on.
enum LiveEvent: Equatable {
    case setupComplete
    case interrupted
    case audio(Data)
    /// Transcription of the user's speech, in pieces.
    case heard(String)
    /// Transcription of the companion's speech, in pieces.
    case said(String)
    /// `finished` never arrives on transcripts; the turn boundary is this.
    case turnComplete
    case toolCall(LiveToolCall)
    case toolCallCancellation([String])
    case goAway(timeLeftMs: Int?)
    /// Only a handle the server says it can resume from.
    case resumption(handle: String)
    case usage(LiveUsage)

    static func parse(_ data: Data) -> [LiveEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return parse(root)
    }

    static func parse(_ root: [String: Any]) -> [LiveEvent] {
        var events: [LiveEvent] = []
        if root["setupComplete"] != nil { events.append(.setupComplete) }
        if let content = root["serverContent"] as? [String: Any] {
            // Before any audio in the same message: an interruption is about
            // what is already queued, not about what arrives with it.
            if content["interrupted"] as? Bool == true { events.append(.interrupted) }
            if let text = (content["inputTranscription"] as? [String: Any])?["text"] as? String,
               !text.isEmpty {
                events.append(.heard(text))
            }
            let parts = ((content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any],
                      (inline["mimeType"] as? String)?.hasPrefix("audio/pcm") ?? true,
                      let encoded = inline["data"] as? String,
                      let audio = Data(base64Encoded: encoded), !audio.isEmpty
                else { continue }
                events.append(.audio(audio))
            }
            if let text = (content["outputTranscription"] as? [String: Any])?["text"] as? String,
               !text.isEmpty {
                events.append(.said(text))
            }
            if content["turnComplete"] as? Bool == true { events.append(.turnComplete) }
        }
        if let calls = (root["toolCall"] as? [String: Any])?["functionCalls"] as? [[String: Any]] {
            for call in calls {
                guard let id = call["id"] as? String, let name = call["name"] as? String else { continue }
                let args = call["args"] as? [String: Any] ?? [:]
                let goal = (args["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                events.append(.toolCall(LiveToolCall(
                    id: id,
                    name: name,
                    question: args["question"] as? String,
                    goal: (goal?.isEmpty ?? true) ? nil : goal,
                    nextStep: args["next_step"] as? Bool ?? false,
                    pointsAtCursor: args["points_at_cursor"] as? Bool ?? false
                )))
            }
        }
        if let ids = (root["toolCallCancellation"] as? [String: Any])?["ids"] as? [String] {
            events.append(.toolCallCancellation(ids))
        }
        if let goAway = root["goAway"] as? [String: Any] {
            events.append(.goAway(timeLeftMs: durationMs(goAway["timeLeft"])))
        }
        if let update = root["sessionResumptionUpdate"] as? [String: Any],
           update["resumable"] as? Bool == true,
           let handle = update["newHandle"] as? String, !handle.isEmpty {
            events.append(.resumption(handle: handle))
        }
        if let metadata = root["usageMetadata"] as? [String: Any] {
            events.append(.usage(usage(metadata)))
        }
        return events
    }

    /// Protobuf JSON durations look like "9.5s".
    static func durationMs(_ value: Any?) -> Int? {
        guard let text = value as? String, text.hasSuffix("s"),
              let seconds = Double(text.dropLast()) else { return nil }
        return Int((seconds * 1_000).rounded())
    }

    private static func usage(_ metadata: [String: Any]) -> LiveUsage {
        var usage = LiveUsage()
        usage.prompt = metadata["promptTokenCount"] as? Int ?? 0
        usage.response = metadata["responseTokenCount"] as? Int ?? 0
        usage.total = metadata["totalTokenCount"] as? Int ?? 0
        usage.thoughts = metadata["thoughtsTokenCount"] as? Int ?? 0
        for detail in (metadata["promptTokensDetails"] as? [[String: Any]]) ?? [] {
            let count = detail["tokenCount"] as? Int ?? 0
            switch detail["modality"] as? String {
            case "AUDIO": usage.promptAudio += count
            case "IMAGE", "VIDEO": usage.promptImage += count
            case "TEXT": usage.promptText += count
            default: break
            }
        }
        return usage
    }
}

/// The conversation as the window shows it: transcript pieces merged into
/// lines, a line closing when the speaker changes or the turn ends. The whole
/// session is kept (up to `kept` lines), because the window scrolls back
/// through it and the user copies from it — a sentence the companion said is
/// often the thing they came for (「英語でなんて言えば」).
struct CompanionTranscript: Equatable {
    enum Speaker: Equatable {
        case user
        case companion
    }

    struct Line: Equatable, Identifiable {
        let id: Int
        let speaker: Speaker
        var text: String
        var isFinal: Bool
    }

    private(set) var lines: [Line] = []
    private var nextID = 0
    private static let kept = 200

    mutating func append(_ piece: String, from speaker: Speaker) {
        guard !piece.isEmpty else { return }
        if let last = lines.last, last.speaker == speaker, !last.isFinal {
            lines[lines.count - 1].text += piece
            return
        }
        // A piece of nothing but spaces must not close the other speaker's
        // line: its continuation would land on a line of its own.
        let text = piece.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        endTurn()
        lines.append(Line(id: nextID, speaker: speaker, text: text, isFinal: false))
        nextID += 1
        if lines.count > Self.kept { lines.removeFirst(lines.count - Self.kept) }
    }

    mutating func endTurn() {
        for index in lines.indices { lines[index].isFinal = true }
    }

    /// The companion was cut off: its open line shows that it stopped.
    mutating func cut() {
        guard let last = lines.last, last.speaker == .companion, !last.isFinal else { return }
        lines[lines.count - 1].text += "…"
        lines[lines.count - 1].isFinal = true
    }

    /// Whether a transcript piece holds words at all: the server sends
    /// punctuation and spaces alone, and the no-words rule needs words.
    static func hasWords(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }
}

/// Whether the screen changed enough to show the voice layer again: a 16×16
/// RGB thumbnail compared by mean absolute difference (0 = same, 1 = opposite).
/// The POC's measure and thresholds, so the two can be compared.
enum ScreenSignature {
    static let side = 16
    /// Below this the frame is not sent (POC `frames.ts`).
    static let sendThreshold = 0.01

    static func of(_ image: CGImage) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(side * side * 3)
        for pixel in 0..<(side * side) {
            rgb.append(rgba[pixel * 4])
            rgb.append(rgba[pixel * 4 + 1])
            rgb.append(rgba[pixel * 4 + 2])
        }
        return rgb
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0
        for index in a.indices { sum += abs(Int(a[index]) - Int(b[index])) }
        return Double(sum) / Double(a.count * 255)
    }
}

/// What the companion is told before it says hello, so the greeting can name
/// the app in front (master plan R18 決定3). The persona on the Gateway reads
/// the same words: 「いま前面にあるアプリ」.
enum CompanionGreeting {
    static let start = "（開始）"
    private static let maxTitleCharacters = 200

    static func frontAppNote(appName: String, windowTitle: String?, host: String?) -> String {
        var details: [String] = []
        if let windowTitle = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !windowTitle.isEmpty {
            details.append("ウインドウ「\(String(windowTitle.prefix(maxTitleCharacters)))」")
        }
        if let host, !host.isEmpty { details.append(host) }
        let suffix = details.isEmpty ? "" : "（" + details.joined(separator: "、") + "）"
        return "いま前面にあるアプリ: \(appName)\(suffix)"
    }
}
