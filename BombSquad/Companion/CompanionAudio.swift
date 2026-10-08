import AVFoundation

enum CompanionAudioError: UserPresentableError {
    case noInput
    case converterUnavailable

    var errorDescription: String? {
        "マイクを開けませんでした。入力装置とマイクの許可を確認してください。"
    }
}

/// R18: the companion's ears and mouth.
///
/// The microphone runs through Apple's voice processing (echo cancellation
/// and noise suppression), and `CompanionTurnTaker` decides on this Mac when
/// the user starts and stops talking. What goes up is therefore a stream of
/// turns — activityStart, the user's audio, activityEnd — with silence in
/// between, never the room. That is what keeps the companion's own voice from
/// the speakers out of the conversation (owner's Mac, 2026-10-08: fine with
/// headphones, interrupting and answering itself on the speakers).
///
/// Up: 16 kHz mono PCM16, on the audio thread. Down: 24 kHz mono PCM16 from
/// the model or a bridge clip, thrown away at once on an interruption (R6).
final class CompanionAudio: @unchecked Sendable {
    enum Plan: String, DiagnosticCode {
        /// Voice processing on: echo cancellation, noise suppression.
        case voiceProcessing
        /// Nothing between the microphone and the turn taker. The companion's
        /// voice still cannot open a turn; talking over it needs a louder voice.
        case plain

        var diagnosticCode: String { rawValue }
    }

    /// What goes up to the server, in order. Called on the audio thread.
    enum Uplink {
        case start
        /// 16 kHz mono PCM16 LE: the user's audio inside a turn, silence outside.
        case audio(Data)
        case end
    }

    /// The user's turns as the turn taker saw them. Called on the main thread.
    enum UserTurn {
        /// `overVoice`: the companion was talking; its voice is now paused
        /// until the session settles whether this was a person.
        case started(overVoice: Bool)
        case stopped(CompanionTurnTaker.Stop)
    }

    var onUplink: ((Uplink) -> Void)?
    var onUserTurn: ((UserTurn) -> Void)?
    /// Whether the companion's voice is coming out. Called on the main thread.
    var onSpeakingChanged: ((Bool) -> Void)?
    /// How much of the current voice has been heard, for the transcript:
    /// (generation, frames played). Called on the main thread.
    var onPlayed: ((Int, Int) -> Void)?
    /// RMS of the microphone (0...1). Called on the audio thread.
    var onInputLevel: ((Float) -> Void)?
    /// The graph was rebuilt after a device change: the plan it runs on now,
    /// or nil when it could not start again. Called on the main thread.
    var onRestarted: ((Plan?) -> Void)?

    /// The plan that started, or nil while stopped.
    private(set) var plan: Plan?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false
    )!
    private let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!
    private var converter: AVAudioConverter?
    /// The tap's format as a non-interleaved mono buffer, for the converter.
    private var monoFormat: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?
    #if DEBUG
    private var dump: CompanionAudioDump?
    #endif
    private var startedAt = Date.distantPast
    /// A graph that has just started can report its own settling as a
    /// configuration change; rebuilding on that would never end.
    private static let settleWindow: TimeInterval = 2

    // Shared between the audio thread, the player's callbacks and the main
    // thread; touched only under `lock`.
    private let lock = NSLock()
    private var taker = CompanionTurnTaker()
    private var muted = false
    private var scheduled = 0
    /// Bumped by `flush()`: completions of thrown-away audio are ignored and
    /// the transcript drops what was never heard.
    private var generation = 0
    private var scheduledFrames = 0
    private var playedFrames = 0
    private var voicePaused = false
    private var voiceEndedAt: TimeInterval = -1_000
    private var preRoll: [(time: TimeInterval, pcm: Data)] = []
    private var turnStartedAt: TimeInterval = 0
    private var levels = LevelBook()

    func start() throws {
        do {
            try build(.voiceProcessing)
        } catch {
            Diagnostics.record("companion.audioPlanFailed", details: [
                ("plan", .code(Plan.voiceProcessing)),
                ("status", .count((error as NSError).code)),
            ])
            tearDownEngine()
            do {
                try build(.plain)
            } catch {
                // A player left on an engine that never started raises an
                // exception Swift cannot catch at the next play().
                tearDownEngine()
                throw error
            }
        }
    }

    /// Safe to call when `start()` never ran or failed.
    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        recordLevelBook()
        // The queue is forgotten before the player stops: stopping calls the
        // completion of every buffer still queued, and those must not count
        // as heard.
        forgetQueue()
        tearDownEngine()
    }

    /// Under its own lock: nothing queued, nothing paused, a new generation.
    private func forgetQueue() {
        lock.lock()
        scheduled = 0
        generation += 1
        scheduledFrames = 0
        playedFrames = 0
        voicePaused = false
        lock.unlock()
    }

    /// Muted, the microphone sends silence and a turn in progress ends.
    func setMuted(_ isMuted: Bool) {
        lock.lock()
        muted = isMuted
        // What was heard while muted must not go out as the start of a turn.
        preRoll.removeAll()
        lock.unlock()
    }

    /// Where the voice queued so far ends, and how much of it has played:
    /// a transcript piece tagged with `frames` is shown once `played` reaches it.
    func frameMark() -> (generation: Int, frames: Int, played: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (generation, scheduledFrames, playedFrames)
    }

    /// Queues one piece of voice (24 kHz mono PCM16 LE): the model's, or a
    /// bridge clip. Both go through the voice processor, which is what lets
    /// it take them out of the microphone.
    func play(pcm16 data: Data) {
        let frames = data.count / 2
        guard let player, frames > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: playbackFormat,
                  frameCapacity: AVAudioFrameCount(frames)
              ),
              let destination = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for index in 0..<frames {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                destination[index] = Float(sample) / 32_768
            }
        }
        #if DEBUG
        dump?.gave(buffer)
        #endif
        lock.lock()
        let generation = self.generation
        scheduled += 1
        scheduledFrames += frames
        let paused = voicePaused
        // Posted under the lock, so "speaking" and "silent" reach the main
        // thread in the order the queue went through them.
        if scheduled == 1 { notifySpeaking(true) }
        lock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.finishedPlaying(frames: frames, generation: generation)
        }
        // A voice paused for the user stays paused; what arrives meanwhile
        // waits behind it. A stopped engine raises on play().
        if !paused, !player.isPlaying, engine?.isRunning == true { player.play() }
    }

    /// Drops everything queued or paused: the user took the floor, or the
    /// turn was abandoned.
    func flush() {
        let now = Self.now()
        lock.lock()
        let wasAudible = scheduled > 0 && !voicePaused
        scheduled = 0
        generation += 1
        scheduledFrames = 0
        playedFrames = 0
        voicePaused = false
        // A voice cut off mid-word still rings in the room; a paused one
        // stopped ringing while it waited.
        if wasAudible { voiceEndedAt = now }
        notifySpeaking(false)
        lock.unlock()
        player?.stop()
        if engine?.isRunning == true { player?.play() }
    }

    /// The voice paused for a "person" who turned out to be a cough or a
    /// door: it carries on where it stopped.
    func resumeVoice() {
        lock.lock()
        let wasPaused = voicePaused
        voicePaused = false
        lock.unlock()
        guard wasPaused, engine?.isRunning == true else { return }
        player?.play()
    }

    // MARK: - Graph

    private func build(_ plan: Plan) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        let input = engine.inputNode
        if plan == .voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Gain control lifts whatever is left of the echo along with the
            // room; the turn taker's lines are relative to the room's floor,
            // so a steady gain serves it better (two Mac voice-agent projects
            // turn it off for the same reason).
            input.isVoiceProcessingAGCEnabled = false
            // Other apps' sound (a video the user is watching) keeps its
            // level; the default ducks it hard for the whole session.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
        }
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw CompanionAudioError.noInput
        }
        // Mono at the hardware rate: with voice processing on, the input
        // reports several channels (the processor's own layout, with its
        // reference), and a mono tap is the one processed channel.
        guard let tapFormat = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: tapFormat, to: captureFormat)
        else { throw CompanionAudioError.converterUnavailable }
        self.converter = converter
        monoFormat = tapFormat
        input.installTap(onBus: 0, bufferSize: 1_024, format: tapFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        if plan == .voiceProcessing {
            // The processor's two client formats must agree (-10875, build 15).
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: tapFormat)
        }
        #if DEBUG
        if let dump = CompanionAudioDump(given: playbackFormat, mixed: engine.mainMixerNode.outputFormat(forBus: 0)) {
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, _ in
                dump.mixed(buffer)
            }
            self.dump = dump
        }
        #endif
        self.engine = engine
        self.player = player
        engine.prepare()
        try engine.start()
        player.play()
        self.plan = plan
        startedAt = Date()
        observeConfigurationChanges(of: engine)
        Diagnostics.record("companion.audioStarted", details: [
            ("plan", .code(plan)),
            ("bypassed", .flag(plan == .voiceProcessing && input.isVoiceProcessingBypassed)),
            ("agc", .flag(plan == .voiceProcessing && input.isVoiceProcessingAGCEnabled)),
            ("micMode", .code(MicrophoneMode.current)),
            ("hwChannels", .count(Int(input.inputFormat(forBus: 0).channelCount))),
        ] + Self.formatDetails(engine))
    }

    /// The user's choice in Control Center (Standard, Voice Isolation, Wide
    /// Spectrum) overrides what the app asks of the voice processor.
    private enum MicrophoneMode: String, DiagnosticCode {
        case standard
        case voiceIsolation
        case wideSpectrum
        case unknown

        static var current: MicrophoneMode {
            switch AVCaptureDevice.activeMicrophoneMode {
            case .standard: return .standard
            case .voiceIsolation: return .voiceIsolation
            case .wideSpectrum: return .wideSpectrum
            @unknown default: return .unknown
            }
        }

        var diagnosticCode: String { rawValue }
    }

    private func tearDownEngine() {
        guard let engine else {
            plan = nil
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        #if DEBUG
        if dump != nil { engine.mainMixerNode.removeTap(onBus: 0) }
        dump = nil
        #endif
        player?.stop()
        engine.stop()
        if engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        self.engine = nil
        player = nil
        plan = nil
    }

    /// Rates and channel counts on both sides — the numbers the voice
    /// processor compares.
    private static func formatDetails(_ engine: AVAudioEngine) -> [(StaticString, DiagnosticValue)] {
        let input = engine.inputNode.outputFormat(forBus: 0)
        let output = engine.outputNode.outputFormat(forBus: 0)
        return [
            ("inRate", .count(Int(input.sampleRate))),
            ("inChannels", .count(Int(input.channelCount))),
            ("outRate", .count(Int(output.sampleRate))),
            ("outChannels", .count(Int(output.channelCount))),
        ]
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    /// A device came or went (headphones, a display with speakers). The
    /// engine stops itself and the formats may have changed, so the graph is
    /// built again. A change while the graph settles is ignored only if the
    /// engine kept running.
    private func restartAfterConfigurationChange() {
        let settling = Date().timeIntervalSince(startedAt) < Self.settleWindow
        let running = engine?.isRunning ?? false
        Diagnostics.record("companion.audioReconfigured", details: [
            ("ignored", .flag(settling && running)),
        ])
        guard !(settling && running) else { return }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        forgetQueue()
        tearDownEngine()
        lock.lock()
        notifySpeaking(false)
        lock.unlock()
        do {
            try start()
            onRestarted?(plan)
        } catch {
            Diagnostics.record("companion.audioRestartFailed", details: [
                ("error", .code(DiagnosticErrorClass(error))),
            ])
            onRestarted?(nil)
        }
    }

    // MARK: - Capture

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let monoFormat,
              !buffer.format.isInterleaved,
              let source = buffer.floatChannelData?[0],
              buffer.frameLength > 0
        else { return }
        let frames = Int(buffer.frameLength)
        let levelDb = CompanionTurnTaker.level(of: source, count: frames)
        onInputLevel?(pow(10, levelDb / 20))
        // Converted every time, sent or not: the resampler keeps its state
        // across buffers, so the start of a turn joins cleanly.
        guard let pcm = convert(source, frames: frames, format: monoFormat, with: converter) else {
            return
        }
        let duration = Double(frames) / buffer.format.sampleRate
        let now = Self.now()

        lock.lock()
        let voice: CompanionTurnTaker.Voice = voicePaused
            ? .paused
            : (scheduled > 0 ? .playing : .ended(at: voiceEndedAt))
        var event: CompanionTurnTaker.Event = .none
        if muted {
            if taker.forceStop() { event = .stopped(.muted) }
        } else {
            event = taker.process(levelDb: levelDb, duration: duration, now: now, voice: voice)
        }
        let speaking = taker.userSpeaking
        var preRolled: [Data] = []
        if case .started(let overVoice, let since) = event {
            preRolled = preRoll.filter { $0.time >= since - 1e-6 }.map(\.pcm)
            preRoll.removeAll()
            if overVoice { voicePaused = true }
            turnStartedAt = now
        } else if !muted {
            preRoll.append((now, pcm))
            while let first = preRoll.first, now - first.time > taker.settings.preRollMax + 0.1 {
                preRoll.removeFirst()
            }
        }
        levels.note(levelDb, voice: voice == .playing, user: speaking || event != .none)
        let utterance = taker.utterance
        let floor = taker.floorDb
        let echo = taker.echoDb
        let turnMs = Int((now - turnStartedAt) * 1_000)
        lock.unlock()

        switch event {
        case .started(let overVoice, _):
            onUplink?(.start)
            for chunk in preRolled { onUplink?(.audio(chunk)) }
            onUplink?(.audio(pcm))
            DispatchQueue.main.async { [weak self] in
                if overVoice { self?.player?.pause() }
                self?.onUserTurn?(.started(overVoice: overVoice))
            }
            Diagnostics.record("companion.userStarted", details: [
                ("overVoice", .flag(overVoice)),
                ("lineDb", .count(Int(utterance.lineDb.rounded()))),
                ("floorDb", .count(Int((floor ?? -120).rounded()))),
                ("echoDb", .count(Int((echo ?? -120).rounded()))),
                ("preRollMs", .ms(preRolled.count * Int(duration * 1_000))),
            ])
        case .stopped(let stop):
            if stop != .muted { onUplink?(.audio(pcm)) }
            onUplink?(.end)
            DispatchQueue.main.async { [weak self] in
                self?.onUserTurn?(.stopped(stop))
            }
            Diagnostics.record("companion.userStopped", details: [
                ("stop", .code(stop)),
                ("ms", .ms(turnMs)),
                ("meanDb", .count(Int(utterance.meanDb.rounded()))),
                ("peakDb", .count(Int(utterance.peakDb.rounded()))),
                ("overVoice", .flag(utterance.overVoice)),
            ])
        case .none:
            onUplink?(.audio(speaking ? pcm : Data(count: pcm.count)))
        }
    }

    private func convert(
        _ source: UnsafePointer<Float>,
        frames: Int,
        format: AVAudioFormat,
        with converter: AVAudioConverter
    ) -> Data? {
        guard let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let monoSamples = mono.floatChannelData?[0]
        else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        monoSamples.update(from: source, count: frames)
        let ratio = captureFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        // `.noDataNow`, not end of stream: the resampler keeps its state.
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }

    // MARK: - Playback bookkeeping

    private func finishedPlaying(frames: Int, generation: Int) {
        let now = Self.now()
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        scheduled = max(0, scheduled - 1)
        playedFrames += frames
        let played = playedFrames
        if scheduled == 0 {
            voiceEndedAt = now
            notifySpeaking(false)
        }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onPlayed?(generation, played)
        }
    }

    private func notifySpeaking(_ speaking: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onSpeakingChanged?(speaking)
        }
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: - What the microphone heard (diagnostics)

    /// Levels over the whole session in three bins: the room (nobody
    /// talking), the companion's voice playing (its echo), and the user's
    /// turns. The lines the turn taker draws only work if the three stay
    /// apart; this is how a session on the speakers says whether they did.
    private struct LevelBook {
        private var room = [Int](repeating: 0, count: 121)
        private var echo = [Int](repeating: 0, count: 121)
        private var user = [Int](repeating: 0, count: 121)

        mutating func note(_ levelDb: Float, voice: Bool, user isUser: Bool) {
            let bin = min(120, max(0, Int((-levelDb).rounded())))
            if isUser {
                user[bin] += 1
            } else if voice {
                echo[bin] += 1
            } else {
                room[bin] += 1
            }
        }

        /// The level `fraction` of the blocks stay at or below, in dBFS.
        func percentile(_ fraction: Double, of bins: KeyPath<LevelBook, [Int]>) -> Int {
            let counts = self[keyPath: bins]
            let total = counts.reduce(0, +)
            guard total > 0 else { return -120 }
            // Bins run loud (0 dB) to quiet (-120 dB); the loudest `1 - fraction`.
            var seen = 0
            let wanted = Int(Double(total) * (1 - fraction))
            for (index, count) in counts.enumerated() {
                seen += count
                if seen > wanted { return -index }
            }
            return -120
        }

        func count(_ bins: KeyPath<LevelBook, [Int]>) -> Int {
            self[keyPath: bins].reduce(0, +)
        }

        var roomBins: [Int] { room }
        var echoBins: [Int] { echo }
        var userBins: [Int] { user }
    }

    private func recordLevelBook() {
        lock.lock()
        let book = levels
        levels = LevelBook()
        lock.unlock()
        Diagnostics.record("companion.levels", details: [
            ("roomP50", .count(book.percentile(0.5, of: \.roomBins))),
            ("roomP90", .count(book.percentile(0.9, of: \.roomBins))),
            ("echoP50", .count(book.percentile(0.5, of: \.echoBins))),
            ("echoP90", .count(book.percentile(0.9, of: \.echoBins))),
            ("echoP99", .count(book.percentile(0.99, of: \.echoBins))),
            ("userP50", .count(book.percentile(0.5, of: \.userBins))),
            ("userP90", .count(book.percentile(0.9, of: \.userBins))),
            ("roomBlocks", .count(book.count(\.roomBins))),
            ("echoBlocks", .count(book.count(\.echoBins))),
            ("userBlocks", .count(book.count(\.userBins))),
        ])
    }
}

#if DEBUG
/// DEBUG only: two recordings of the companion's voice per audio graph in
/// /tmp/universal-io-companion-audio (never the user's). `given` is every
/// piece handed to the player, back to back; `mixed` is what the engine sent
/// on to the output, in real time. The owner hears replies start mid-sentence
/// while Gemini's audio starts whole (CLI, 5 of 5 greetings): a start present
/// in `mixed` but not heard was lost after the engine (voice processing or the
/// speakers), one missing from `mixed` was lost in the app.
private final class CompanionAudioDump {
    private let givenFile: AVAudioFile
    private let mixedFile: AVAudioFile

    init?(given: AVAudioFormat, mixed: AVAudioFormat) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        let directory = URL(fileURLWithPath: "/tmp/universal-io-companion-audio", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            givenFile = try Self.file(directory.appendingPathComponent("\(stamp)-given.wav"), given)
            mixedFile = try Self.file(directory.appendingPathComponent("\(stamp)-mixed.wav"), mixed)
            NSLog("Companion audio dump: %@/%@-*.wav", directory.path, stamp)
        } catch {
            NSLog("Companion audio dump failed: %@", String(describing: error))
            return nil
        }
    }

    /// Main thread.
    func gave(_ buffer: AVAudioPCMBuffer) {
        try? givenFile.write(from: buffer)
    }

    /// The mixer's tap thread.
    func mixed(_ buffer: AVAudioPCMBuffer) {
        try? mixedFile.write(from: buffer)
    }

    private static func file(_ url: URL, _ format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }
}
#endif
