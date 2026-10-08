import AVFoundation

enum CompanionAudioError: UserPresentableError {
    case noInput
    case converterUnavailable

    var errorDescription: String? {
        "マイクを開けませんでした。入力装置とマイクの許可を確認してください。"
    }
}

/// The companion's ears and mouth: one `AVAudioEngine` with Apple's voice
/// processing on, so the companion's own voice coming out of the speakers is
/// cancelled out of the microphone. The POC needed Chrome's AEC "all" for the
/// same thing; without it the model hears itself and stops mid-sentence.
/// Headphones are not assumed (requirements R5).
///
/// Up: 16 kHz mono PCM16, on the audio thread. Down: 24 kHz mono PCM16 from
/// the model, thrown away at once on an interruption (R6).
final class CompanionAudio: @unchecked Sendable {
    /// 16 kHz mono PCM16 LE. Called on the audio thread.
    var onCapture: ((Data) -> Void)?
    /// Whether the companion's voice is coming out. Called on the main thread.
    var onSpeakingChanged: ((Bool) -> Void)?
    /// RMS of the microphone (0...1). Called on the audio thread.
    var onInputLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
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
    private var isRunning = false

    func start() throws {
        let input = engine.inputNode
        // On either node it turns on for both: the output is the reference the
        // canceller subtracts from the input.
        try input.setVoiceProcessingEnabled(true)
        // Other apps' sound (a video the user is watching) stays at its level;
        // the default ducks it hard for the whole session.
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        try installCapture()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    /// Safe to call when `start()` never ran or failed halfway.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
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
        guard frames > 0,
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
        player.stop()
        player.play()
        notifySpeaking(false)
    }

    // MARK: - Capture

    private func installCapture() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CompanionAudioError.noInput
        }
        // With voice processing on, macOS can hand the tap more than one
        // channel; only the first is the processed voice.
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: mono, to: captureFormat) else {
            throw CompanionAudioError.converterUnavailable
        }
        monoFormat = mono
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
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

    /// A device came or went (headphones, a display with speakers). The
    /// engine stops itself; the input format may have changed with it.
    private func restartAfterConfigurationChange() {
        Diagnostics.record("companion.audioReconfigured")
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installCapture()
            engine.prepare()
            try engine.start()
            player.play()
        } catch {
            Diagnostics.record("companion.audioRestartFailed", details: [
                ("error", .code(DiagnosticErrorClass(error))),
            ])
        }
    }
}
