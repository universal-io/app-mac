import AVFoundation
import Speech

/// Build 37 (experiment): on-device speech recognition running beside the
/// Live connection, for the words of the user's turn while it is still being
/// spoken. Gemini's transcript of a turn arrives after the turn ends; Apple's
/// partial results arrive during it. Only the reflex reads these partials —
/// nothing here is shown, sent to the voice, or kept. Recognition stays on
/// this Mac: when the system cannot recognise Japanese on device, the ear
/// does not listen at all rather than send audio to a second cloud.
final class CompanionEar: @unchecked Sendable {
    enum Availability: String {
        case unknown, onDevice, denied, unsupported, unavailable
    }

    private(set) var availability: Availability = .unknown
    /// The words of the current turn so far, as they change. Main thread.
    var onPartial: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var turn = 0

    /// Asks for permission (the system prompts once) and checks that Japanese
    /// can be recognised on this Mac without leaving it.
    func prepare() async {
        guard let recognizer else {
            availability = .unavailable
            return
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            availability = .denied
            return
        }
        availability = recognizer.supportsOnDeviceRecognition && recognizer.isAvailable ? .onDevice : .unsupported
        Diagnostics.record("companion.ear", details: [("availability", .code(availability))])
    }

    var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return request != nil
    }

    /// A turn has started: partials of it will follow on `onPartial`.
    func begin() {
        guard availability == .onDevice, let recognizer else { return }
        lock.lock()
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        self.request = request
        turn += 1
        let thisTurn = turn
        lock.unlock()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            let current = self.turn == thisTurn
            self.lock.unlock()
            guard current else { return }
            if let result {
                let words = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.onPartial?(words) }
            }
            if error != nil || result?.isFinal == true {
                self.lock.lock()
                if self.turn == thisTurn { self.request = nil }
                self.lock.unlock()
            }
        }
    }

    /// 16 kHz mono Int16 PCM of the turn, as the audio graph captures it.
    /// Called on the audio thread.
    func feed(_ pcm: Data) {
        lock.lock()
        let request = self.request
        lock.unlock()
        guard let request, !pcm.isEmpty else { return }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.int16ChannelData
        else { return }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            channel[0].update(from: base.assumingMemoryBound(to: Int16.self), count: Int(frames))
        }
        request.append(buffer)
    }

    /// The turn ended: the recogniser finishes with what it has.
    func end() {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.endAudio()
    }

    func cancel() {
        lock.lock()
        request = nil
        turn += 1
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

extension CompanionEar.Availability: DiagnosticCode {
    var diagnosticCode: String { rawValue }
}
