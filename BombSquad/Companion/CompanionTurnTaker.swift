import Foundation

/// R18: when the user starts and stops talking, decided on this Mac from the
/// microphone, block by block. The server is told with activityStart and
/// activityEnd and hears nothing outside those stretches.
///
/// Measured against gemini-3.8-live on 2026-10-08: left to itself, the
/// server ended Japanese turns at short pauses (「そんな」 of 「そんなボタンは
/// ありませんよ」 became a turn, was answered, and the rest was half lost), and
/// on the built-in speakers it took the companion's own voice for the user.
/// With turns decided here the same audio arrived whole and was understood,
/// and the companion's voice in the room cannot open a turn at all.
///
/// A start needs the level held above a line for most of a short window:
/// - Nothing playing: the room's floor plus a margin.
/// - The companion's voice in the room: also clear of what its echo has been
///   sounding like, and well above the floor (the two tests WebRTC AEC3 uses
///   for a near-end talker). The voice is paused at once by the caller;
///   whether it was a person is settled later by the server's transcript.
/// A stop is a stretch below the floor's quiet line.
///
/// Pure bookkeeping on levels and times, so it can be tested without audio.
struct CompanionTurnTaker {
    struct Settings: Equatable {
        /// Until the room has been heard, its floor is taken to be this (the
        /// owner's Mac idled at −52 to −61 dBFS with voice processing on).
        var assumedFloorDb: Float = -55
        /// The floor climbs toward the quietest moment of the last
        /// `floorWindow` at this rate (a room that got louder: music, a fan);
        /// it falls at once.
        var floorRisePerSecond: Float = 3
        var floorWindow: TimeInterval = 3
        /// Above the floor by this much, nothing playing, is a voice…
        var startMarginDb: Float = 10
        /// …and never below this, however quiet the room. Build 20 on the
        /// owner's Mac: the user's turns averaged −30 dBFS, mouse and keyboard
        /// clicks −60 (peaks −50), and −50 let clicks in.
        var startMinimumDb: Float = -44
        /// Over the companion's voice: above the floor by this much…
        var overFloorMarginDb: Float = 15
        /// …and above what its echo has been by this much…
        var overEchoMarginDb: Float = 10
        /// …and never below this. Echo cancelled down to −100 dBFS (build 20)
        /// put the line at floor + 15 = −61, and clicks over the voice became
        /// turns that the model answered with 「はい」. The echo is not steady
        /// either: its mean stayed near −53 while stretches reached −43 for
        /// 0.2 s, were transcribed as words (「ドラム」), and the companion
        /// answered itself. On the owner's Mac those echo turns averaged −52
        /// to −60 (peaks −43 to −50); the user talking over it averaged −33
        /// (peak −26), and −29 to −33 with nothing playing. A person stopping
        /// the voice speaks up; nothing of the companion's reaches this.
        var overMinimumDb: Float = -36
        /// Echo heard before a voice over it can count at all.
        var echoLearning: TimeInterval = 0.5
        /// The companion's voice played before anything over it may start a
        /// turn. An echo canceller learns from what it has played, not from
        /// the clock: WebRTC AEC3 treats its first 2.5 s of loud playback as
        /// an initial state, and LiveKit Agents blocks interruptions for the
        /// agent's first 3 s of speech for this reason. Build 20 answered its
        /// own echo 1.9 s into the greeting. Levels still count for learning
        /// the echo meanwhile, so a person heard here is not taken for it.
        var aecWarmup: TimeInterval = 3
        var echoTimeConstant: TimeInterval = 2
        /// Above the line for this long within `window` starts a turn. A
        /// syllable of echo or a key press is shorter; a person holds it.
        var hold: TimeInterval = 0.2
        var window: TimeInterval = 0.3
        /// The companion's voice still rings this long after it stopped.
        var tail: TimeInterval = 0.35
        /// Below floor + this margin counts as quiet while the user talks…
        var quietMarginDb: Float = 6
        /// …and this much quiet ends the turn. Japanese phrases pause for
        /// 0.3–0.5 s mid-sentence; this is past that, and short enough that
        /// the answer still comes within about a second and a half.
        var endSilence: TimeInterval = 0.75
        var maxUtterance: TimeInterval = 30
        /// Sent before the first block that counted, so the server hears the
        /// start of the word.
        var preRollLead: TimeInterval = 0.1
        var preRollMax: TimeInterval = 0.5
    }

    /// Whether the companion's voice is coming out of the speakers.
    enum Voice: Equatable {
        case playing
        /// Paused for the user: no echo, nothing to wait out.
        case paused
        /// The last of it played out at this time.
        case ended(at: TimeInterval)
    }

    enum Stop: String, DiagnosticCode {
        case silence
        case maxLength
        case muted

        var diagnosticCode: String { rawValue }
    }

    enum Event: Equatable {
        case none
        /// The user started. Send activityStart, the audio kept since `since`,
        /// then this block. `overVoice`: the companion was talking.
        case started(overVoice: Bool, since: TimeInterval)
        /// The user stopped. Send this block, then activityEnd.
        case stopped(Stop)
    }

    /// One turn of the user's, for the record.
    struct Utterance: Equatable {
        var overVoice = false
        var lineDb: Float = 0
        var peakDb: Float = -120
        var quietestDb: Float = 0
        var power: Double = 0
        var heard: TimeInterval = 0

        var meanDb: Float {
            heard > 0 ? CompanionTurnTaker.decibels(Float(power / heard)) : -120
        }
    }

    let settings: Settings
    private(set) var userSpeaking = false
    private(set) var floorDb: Float?
    private(set) var utterance = Utterance()
    private var echoPower: Float?
    private var echoHeard: TimeInterval = 0
    /// How long the companion's voice has played, all told.
    private var played: TimeInterval = 0
    private var recent: [(time: TimeInterval, duration: TimeInterval, counts: Bool)] = []
    /// Levels of the last `floorWindow` with no voice of the companion's in
    /// the room, whoever was talking: the quietest of them is the room.
    private var quietWindow: [(time: TimeInterval, levelDb: Float)] = []
    private var speakingSince: TimeInterval = 0
    private var lastVoiceAt: TimeInterval = 0

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// What the companion's echo has sounded like, in dBFS.
    var echoDb: Float? {
        echoPower.map(Self.decibels)
    }

    /// The level a start must hold, given what is in the room.
    func line(voiceInRoom: Bool) -> Float? {
        let floor = floorDb ?? settings.assumedFloorDb
        guard voiceInRoom else {
            return max(settings.startMinimumDb, floor + settings.startMarginDb)
        }
        guard let echoPower, echoHeard >= settings.echoLearning else { return nil }
        return max(
            settings.overMinimumDb,
            floor + settings.overFloorMarginDb,
            Self.decibels(echoPower) + settings.overEchoMarginDb
        )
    }

    mutating func process(levelDb: Float, duration: TimeInterval, now: TimeInterval, voice: Voice) -> Event {
        let voiceInRoom: Bool
        switch voice {
        case .playing: voiceInRoom = true
        case .paused: voiceInRoom = false
        case .ended(let end): voiceInRoom = now - end < settings.tail
        }
        if voice == .playing { played += duration }
        if !voiceInRoom { learnFloor(levelDb: levelDb, duration: duration, now: now) }
        if userSpeaking { return continueTurn(levelDb: levelDb, duration: duration, now: now) }

        let line = line(voiceInRoom: voiceInRoom)
        let counts = line.map { levelDb >= $0 } ?? false
        let warming = voiceInRoom && played < settings.aecWarmup
        recent.append((now, duration, counts && !warming))
        while let first = recent.first, now - first.time > settings.window {
            recent.removeFirst()
        }
        if !counts, voice == .playing {
            learnEcho(levelDb: levelDb, duration: duration)
        }
        let held = recent.reduce(0) { $0 + ($1.counts ? $1.duration : 0) }
        guard held >= settings.hold, let line else { return .none }

        let firstCounted = recent.first(where: { $0.counts })?.time ?? now
        let since = max(firstCounted - settings.preRollLead, now - settings.preRollMax)
        recent.removeAll()
        userSpeaking = true
        speakingSince = now
        lastVoiceAt = now
        utterance = Utterance(overVoice: voiceInRoom, lineDb: line)
        note(levelDb, duration: duration)
        return .started(overVoice: voiceInRoom, since: since)
    }

    /// Mute while the user is talking: the turn ends here.
    mutating func forceStop() -> Bool {
        guard userSpeaking else { return false }
        userSpeaking = false
        return true
    }

    private mutating func continueTurn(levelDb: Float, duration: TimeInterval, now: TimeInterval) -> Event {
        note(levelDb, duration: duration)
        let floor = floorDb ?? settings.assumedFloorDb
        if levelDb >= max(settings.startMinimumDb - settings.startMarginDb, floor + settings.quietMarginDb) {
            lastVoiceAt = now
        }
        if now - lastVoiceAt >= settings.endSilence {
            userSpeaking = false
            return .stopped(.silence)
        }
        if now - speakingSince >= settings.maxUtterance {
            userSpeaking = false
            // A turn this long is most likely the room, not a person: what it
            // never went below is the floor from here.
            if utterance.quietestDb > -100 { floorDb = utterance.quietestDb }
            return .stopped(.maxLength)
        }
        return .none
    }

    private mutating func note(_ levelDb: Float, duration: TimeInterval) {
        utterance.peakDb = max(utterance.peakDb, levelDb)
        utterance.quietestDb = utterance.heard == 0 ? levelDb : min(utterance.quietestDb, levelDb)
        utterance.power += Double(Self.power(levelDb)) * duration
        utterance.heard += duration
    }

    private mutating func learnEcho(levelDb: Float, duration: TimeInterval) {
        let power = Self.power(levelDb)
        if let echoPower {
            let weight = Float(min(1, duration / settings.echoTimeConstant))
            self.echoPower = echoPower + (power - echoPower) * weight
        } else {
            echoPower = power
        }
        echoHeard += duration
    }

    /// Minimum statistics: the floor falls to any quieter moment at once,
    /// and rises only toward the quietest moment of the last few seconds —
    /// so speech, which always dips between words, cannot lift it, while a
    /// room that stays louder does within seconds.
    private mutating func learnFloor(levelDb: Float, duration: TimeInterval, now: TimeInterval) {
        // Digital silence (an engine still starting, a muted device) is not
        // the room; learned, it would leave the floor 60 dB too low.
        guard levelDb > -100 else { return }
        quietWindow.append((now, levelDb))
        while let first = quietWindow.first, now - first.time > settings.floorWindow {
            quietWindow.removeFirst()
        }
        guard let floorDb else {
            // Never seeded above the assumed room: the first block may well be
            // the user, who started talking the moment the window opened. A
            // room that really is louder lifts it within seconds.
            floorDb = min(levelDb, settings.assumedFloorDb)
            return
        }
        if levelDb < floorDb {
            // Falls within about a tenth of a second: a quiet moment is the
            // room's truth, a loud one may be anything.
            self.floorDb = floorDb + (levelDb - floorDb) * Float(min(1, duration / 0.1))
            return
        }
        guard let first = quietWindow.first, now - first.time >= settings.floorWindow * 0.8,
              let quietest = quietWindow.map(\.levelDb).min(), quietest > floorDb
        else { return }
        self.floorDb = floorDb + min(quietest - floorDb, settings.floorRisePerSecond * Float(duration))
    }

    static func decibels(_ power: Float) -> Float {
        guard power > 0 else { return -120 }
        return max(-120, 10 * log10(power))
    }

    static func power(_ decibels: Float) -> Float {
        pow(10, decibels / 10)
    }

    /// RMS of a block in dBFS.
    static func level(of samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return -120 }
        var energy: Float = 0
        for index in 0..<count { energy += samples[index] * samples[index] }
        return decibels(energy / Float(count))
    }
}
