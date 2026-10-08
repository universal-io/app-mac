import AVFoundation

enum CompanionAudioError: UserPresentableError {
    case noInput
    case converterUnavailable

    var errorDescription: String? {
        "マイクを開けませんでした。入力装置とマイクの許可を確認してください。"
    }
}

/// The companion's ears and mouth: an `AVAudioEngine` with Apple's voice
/// processing on, so the companion's own voice coming out of the speakers is
/// cancelled out of the microphone. The POC needed Chrome's AEC "all" for the
/// same thing; without it the model hears itself and stops mid-sentence.
/// Headphones are not assumed (requirements R5).
///
/// Up: 16 kHz mono PCM16, on the audio thread. Down: 24 kHz mono PCM16 from
/// the model, thrown away at once on an interruption (R6).
final class CompanionAudio: @unchecked Sendable {
    /// How the graph is wired. Tried in order until one starts.
    ///
    /// Build 17 on the owner's Mac (2026-10-08): the engine started with
    /// voice processing on, yet the model interrupted itself ~400 ms into
    /// every sentence — its own voice from the speakers, heard as the user.
    /// Two things in that build were wrong, both documented by others who
    /// hit the same wall:
    ///
    /// - Voice processing was enabled before the playback graph existed.
    ///   The processor takes what it is playing as the reference it
    ///   subtracts; enabled first, it starts with no output bus and cancels
    ///   nothing (field reports on VoiceProcessingIO, 2026).
    /// - The tap took channel 0 of whatever the input node reported. With
    ///   voice processing on, macOS reports the aggregate it built — 9
    ///   channels on that Mac (built-in mic plus BlackHole, Teams, iPhone) —
    ///   and channel 0 is not promised to be the processed voice. A tap
    ///   installed with a mono format gets the one processed channel
    ///   (Apple forum 771530).
    ///
    /// Build 15 had shown the other constraint: the processor's client
    /// formats on both sides must agree, or initialization fails with
    /// -10875. So the mixer is connected to the output in the tap's format.
    enum Plan: String, CaseIterable, DiagnosticCode {
        /// Playback wired first, mono tap, output in the tap's format.
        case playbackFirstMono
        /// Playback wired first, tap and output in the input node's format.
        case playbackFirstMatched
        /// Voice processing first, mono tap. Build 17's order, better tap.
        case processingFirstMono
        /// Build 17's exact wiring: known to start, known not to cancel.
        case processingFirstMatched
        /// No echo cancellation: works anywhere, needs headphones.
        case withoutVoiceProcessing

        var diagnosticCode: String { rawValue }
        var cancelsEcho: Bool { self != .withoutVoiceProcessing }
        var playbackFirst: Bool { self == .playbackFirstMono || self == .playbackFirstMatched }
        var monoTap: Bool { self == .playbackFirstMono || self == .processingFirstMono }
    }

    /// 16 kHz mono PCM16 LE. Called on the audio thread.
    var onCapture: ((Data) -> Void)?
    /// Whether the companion's voice is coming out. Called on the main thread.
    var onSpeakingChanged: ((Bool) -> Void)?
    /// RMS of the microphone (0...1). Called on the audio thread.
    var onInputLevel: ((Float) -> Void)?

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

    private let lock = NSLock()
    private var muted = false
    private var scheduled = 0
    /// Bumped by `flush()` so completions of thrown-away audio are ignored.
    private var generation = 0
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?
    private var startedAt = Date.distantPast
    /// A graph that has just started can report its own settling as a
    /// configuration change; rebuilding on that would never end.
    private static let settleWindow: TimeInterval = 2

    func start() throws {
        var lastError: Error = CompanionAudioError.noInput
        for plan in Plan.allCases {
            // A fresh engine per attempt: a graph that failed to initialize
            // keeps its half-made connections.
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            do {
                try build(engine, player, plan)
                self.engine = engine
                self.player = player
                self.plan = plan
                startedAt = Date()
                observeConfigurationChanges(of: engine)
                return
            } catch {
                lastError = error
                Diagnostics.record("companion.audioPlanFailed", details: [
                    ("plan", .code(plan)),
                    ("status", .count((error as NSError).code)),
                ] + Self.formatDetails(engine))
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                try? engine.inputNode.setVoiceProcessingEnabled(false)
            }
        }
        throw lastError
    }

    /// Safe to call when `start()` never ran or failed.
    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        player?.stop()
        engine.stop()
        if plan?.cancelsEcho == true {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        self.engine = nil
        player = nil
        plan = nil
        setScheduled(0, bumpGeneration: true)
    }

    func setMuted(_ isMuted: Bool) {
        lock.lock()
        muted = isMuted
        lock.unlock()
    }

    /// Queues one piece of the model's voice (24 kHz mono PCM16 LE).
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
        lock.lock()
        let generation = self.generation
        scheduled += 1
        let began = scheduled == 1
        lock.unlock()
        if began { notifySpeaking(true) }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.finishedPlaying(generation: generation)
        }
        if !player.isPlaying { player.play() }
    }

    /// Drops everything queued. The interruption path: the user started
    /// talking, so the rest of the sentence is no longer wanted.
    func flush() {
        setScheduled(0, bumpGeneration: true)
        player?.stop()
        player?.play()
        notifySpeaking(false)
    }

    // MARK: - Graph

    private func build(_ engine: AVAudioEngine, _ player: AVAudioPlayerNode, _ plan: Plan) throws {
        let input = engine.inputNode
        if plan.playbackFirst { wirePlayback(engine, player) }
        if plan.cancelsEcho {
            // On either node it turns on for both: the output is the reference
            // the canceller subtracts from the input.
            try input.setVoiceProcessingEnabled(true)
            // Other apps' sound (a video the user is watching) stays at its
            // level; the default ducks it hard for the whole session.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CompanionAudioError.noInput
        }
        let tapFormat: AVAudioFormat
        if plan.monoTap {
            guard let mono = AVAudioFormat(
                standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1
            ) else { throw CompanionAudioError.converterUnavailable }
            tapFormat = mono
        } else {
            tapFormat = inputFormat
        }
        try installCapture(on: input, format: tapFormat)
        if !plan.playbackFirst { wirePlayback(engine, player) }
        if plan.cancelsEcho {
            // The processor's two client formats have to agree (-10875
            // otherwise): what leaves the input bus and what reaches the
            // output bus.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: tapFormat)
        }
        engine.prepare()
        try engine.start()
        player.play()
        Diagnostics.record("companion.audioStarted", details: [
            ("plan", .code(plan)),
            ("tapChannels", .count(Int(tapFormat.channelCount))),
        ] + Self.formatDetails(engine))
    }

    private func wirePlayback(_ engine: AVAudioEngine, _ player: AVAudioPlayerNode) {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
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
    /// built again from the first plan.
    private func restartAfterConfigurationChange() {
        let settling = Date().timeIntervalSince(startedAt) < Self.settleWindow
        Diagnostics.record("companion.audioReconfigured", details: [("ignored", .flag(settling))])
        guard !settling else { return }
        stop()
        do {
            try start()
        } catch {
            Diagnostics.record("companion.audioRestartFailed", details: [
                ("error", .code(DiagnosticErrorClass(error))),
            ])
        }
    }

    // MARK: - Capture

    private func installCapture(on input: AVAudioInputNode, format tapFormat: AVAudioFormat) throws {
        // Whatever the tap delivers, only its first channel is used: the one
        // processed channel for a mono tap, and channel 0 otherwise.
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: mono, to: captureFormat) else {
            throw CompanionAudioError.converterUnavailable
        }
        monoFormat = mono
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1_024, format: tapFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let monoFormat, let converter,
              !buffer.format.isInterleaved,
              let source = buffer.floatChannelData?[0],
              buffer.frameLength > 0,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let monoSamples = mono.floatChannelData?[0]
        else { return }
        let frames = Int(buffer.frameLength)
        mono.frameLength = buffer.frameLength
        monoSamples.update(from: source, count: frames)

        var energy: Float = 0
        for index in 0..<frames { energy += source[index] * source[index] }
        onInputLevel?((energy / Float(frames)).squareRoot())

        lock.lock()
        let isMuted = muted
        lock.unlock()
        guard !isMuted else { return }

        let ratio = captureFormat.sampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        // `.noDataNow`, not end of stream: the resampler keeps its state
        // across buffers, so the joins between chunks stay clean.
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
              let samples = output.int16ChannelData?[0] else { return }
        onCapture?(Data(bytes: samples, count: Int(output.frameLength) * 2))
    }

    // MARK: - Playback bookkeeping

    private func finishedPlaying(generation: Int) {
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        scheduled = max(0, scheduled - 1)
        let ended = scheduled == 0
        lock.unlock()
        if ended { notifySpeaking(false) }
    }

    private func setScheduled(_ count: Int, bumpGeneration: Bool) {
        lock.lock()
        scheduled = count
        if bumpGeneration { generation += 1 }
        lock.unlock()
    }

    private func notifySpeaking(_ speaking: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onSpeakingChanged?(speaking)
        }
    }
}
