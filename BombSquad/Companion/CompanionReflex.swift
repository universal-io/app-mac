import AppKit

/// Build 37 (experiment): the companion's reflex. A System One decision model
/// (TypeSafe Jev, through Gateway `/ai/decide`) answers typed questions in
/// about half a second for a fraction of a yen. It never speaks and never
/// plans; it only decides. Here it is asked, while the user is still talking,
/// whether the words are about the screen and which reading would answer
/// them — so the eye can start before the guide calls look_closely — and,
/// once the eye has answered, whether the controls the answer names are on
/// the screen at all.
///
/// Measured on 41 recorded utterances (2026-10-11): 37/41 right at full and
/// at half length; firing the eye at p(screen) >= 0.7 was wrong 0 times.
@MainActor
final class CompanionReflex {
    /// Which experiment the session runs. `defaults write com.universal-io.mac.dev
    /// companion.reflexArm -string off|generic|aimed` (Debug; the release bundle
    /// is com.universal-io.mac); the default is aimed.
    enum Arm: String {
        /// No reflex: the eye starts when the guide calls look_closely.
        case off
        /// The eye reads the screen for a general description at the start of
        /// every turn, with no judgement.
        case generic
        /// The reflex judges the words as they come; the eye starts once it
        /// is confident they are about the screen.
        case aimed

        static let defaultsKey = "companion.reflexArm"

        static var current: Arm {
            Arm(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .aimed
        }
    }

    struct Verdict: Equatable {
        enum Kind: String {
            case screen, conversation, unclear
        }

        enum ReadType: String {
            case describe, locate, readText = "read_text", howTo = "how_to", evaluate, none
        }

        let kind: Kind
        let pScreen: Double
        let confidence: Double
        let readType: ReadType
        let aboutScreen: Double
        let latencyMs: Int

        /// Whether the eye should start on this verdict alone.
        var fires: Bool { pScreen >= CompanionReflex.fireThreshold && readType != .none }
    }

    struct Grounding: Equatable {
        /// 0...1: every control the answer names in 「」 is in the visible list.
        let allPresent: Double
        let verdict: String
        let confidence: Double
        let latencyMs: Int
    }

    /// Above this the eye starts on the reflex's word. 0 of 41 recorded
    /// utterances fired wrongly at this line, at full and at half length.
    static let fireThreshold = 0.7
    /// A reflex that is slower than this is no reflex: the look it would have
    /// started is about as far off as the guide's own call.
    private static let timeout: TimeInterval = 4

    private let client: GatewayClient

    /// Nil when signed out, like every other Gateway client.
    init?() {
        guard let client = GatewayClient.make() else { return nil }
        self.client = client
    }

    /// The user's words so far (they may be cut off mid-sentence), judged
    /// against the app in front and a sample of what is on screen.
    func judgeUtterance(_ words: String, app: String?, visibleElements: String?) async -> Verdict? {
        let state: [String: Any] = [
            "app_in_front": app ?? "",
            "visible_elements_sample": String((visibleElements ?? "").prefix(1_500)),
            "user_said": String(words.prefix(600)),
        ]
        let questions: [String: Any] = [
            "kind": [
                "type": "choice",
                "instructions": "The user is talking to a voice assistant that sits beside them and can see their screen. Classify the user's latest words (possibly cut off mid-sentence).",
                "criteria": [
                    "screen": "Needs the screen to answer well: asks what is shown, where/which control, what something on screen means or does, how to do something in this app, or to summarize/evaluate visible content.",
                    "conversation": "Answerable without the screen: chit-chat, general knowledge or definitions, translating or rephrasing what the user said, reactions and acknowledgements.",
                    "unclear": "Fragment, noise, or not a request.",
                ],
            ],
            "read_type": [
                "type": "choice",
                "instructions": "If the assistant should read the screen, which reading would answer the user?",
                "criteria": [
                    "describe": "Describe what this screen/area is or what is displayed.",
                    "locate": "Find where a control is or what a named control does.",
                    "read_text": "Read or summarize text content that is on screen.",
                    "how_to": "Give the next step to achieve something in this app.",
                    "evaluate": "Judge or advise about visible content (e.g., a message, a listing).",
                    "none": "No reading needed.",
                ],
            ],
            "about_screen": [
                "type": "noul",
                "instructions": "The user's words refer to something currently visible on their screen (deictic words like これ/この/ここ/右上/左側 or named on-screen items count).",
            ],
        ]
        guard let (answers, ms) = await decide(state: state, questions: questions),
              let kind = answers["kind"] as? [String: Any],
              let choice = (kind["choice"] as? String).flatMap(Verdict.Kind.init(rawValue:)),
              let probabilities = kind["probabilities"] as? [String: Double],
              let pScreen = probabilities["screen"],
              let confidence = kind["confidence"] as? Double,
              let read = answers["read_type"] as? [String: Any],
              let readType = (read["choice"] as? String).flatMap(Verdict.ReadType.init(rawValue:)),
              let about = answers["about_screen"] as? [String: Any],
              let aboutScreen = about["noul"] as? Double
        else { return nil }
        return Verdict(kind: choice, pScreen: pScreen, confidence: confidence, readType: readType,
                       aboutScreen: aboutScreen, latencyMs: ms)
    }

    /// Whether the controls an answer names exist in what the app can see.
    /// Logged only in build 37: the wording that tells content words
    /// (「pod」) from controls is not settled yet.
    func judgeGrounding(answer: String, visibleElements: String) async -> Grounding? {
        let state: [String: Any] = [
            "visible_elements": String(visibleElements.prefix(6_000)),
            "answer": String(answer.prefix(1_000)),
        ]
        let questions: [String: Any] = [
            "all_present": [
                "type": "noul",
                "instructions": "Every UI control, menu, tab or button that the answer names in 「」 quotes appears in the list of visible elements (allow minor wording differences, e.g. 「Show Canvas」 vs a 'Canvas' radio button).",
            ],
            "grounding": [
                "type": "choice",
                "instructions": "How well is the answer grounded in the visible elements list?",
                "criteria": [
                    "grounded": "Every named control is in the list.",
                    "partly": "Some named controls are in the list, some are not.",
                    "ungrounded": "Named controls are not in the list.",
                    "nothing_named": "The answer names no control.",
                ],
            ],
        ]
        guard let (answers, ms) = await decide(state: state, questions: questions),
              let all = answers["all_present"] as? [String: Any],
              let allPresent = all["noul"] as? Double,
              let grounding = answers["grounding"] as? [String: Any],
              let verdict = grounding["choice"] as? String,
              let confidence = grounding["confidence"] as? Double
        else { return nil }
        return Grounding(allPresent: allPresent, verdict: verdict, confidence: confidence, latencyMs: ms)
    }

    /// One round trip. Nil on any failure or after `timeout`: the caller goes
    /// on without a verdict, as it would without a reflex at all.
    private func decide(state: [String: Any], questions: [String: Any]) async -> ([String: Any], Int)? {
        guard let stateData = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let stateText = String(data: stateData, encoding: .utf8)
        else { return nil }
        let body = GatewayClient.envelope(operation: "decide", input: ["state": stateText, "questions": questions])
        let started = Date()
        do {
            let data = try await client.postJSON("ai/decide", body: body, timeout: Self.timeout)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = root["result"] as? [String: Any],
                  let answers = result["answers"] as? [String: Any]
            else { return nil }
            return (answers, Int(Date().timeIntervalSince(started) * 1_000))
        } catch {
            Diagnostics.record("companion.reflexFailed", details: [
                ("error", .code(DiagnosticErrorClass(error))),
                ("ms", .ms(Int(Date().timeIntervalSince(started) * 1_000))),
            ])
            return nil
        }
    }
}

extension CompanionReflex.Arm: DiagnosticCode {
    var diagnosticCode: String { rawValue }
}
