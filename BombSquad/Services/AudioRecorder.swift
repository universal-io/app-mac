import AVFoundation

enum AudioRecorderError: UserPresentableError {
    case couldNotStart
    var errorDescription: String? {
        "録音を開始できませんでした（マイクの権限を確認してください）。"
    }
}

/// Records mic input to a temporary m4a file for transcription.
/// 16 kHz mono AAC keeps the upload small while staying ample for speech.
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?

    /// Called after AVAudioRecorder reports that stop processing has completed.
    var onFinish: (() -> Void)?

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jam-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.prepareToRecord()
        guard recorder.record() else { throw AudioRecorderError.couldNotStart }
        self.recorder = recorder
        self.fileURL = url
    }

    /// Touch the audio system once so the first real recording starts faster.
    func warmUp() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jam-warmup.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        if let warm = try? AVAudioRecorder(url: url, settings: settings) {
            warm.prepareToRecord()
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Stops recording and returns the captured file URL. The recorder is kept
    /// alive until the finish delegate fires, then released.
    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        return fileURL
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        onFinish?()
        onFinish = nil
        self.recorder = nil
    }
}

extension AudioRecorder {
    /// Duration and average loudness of a recorded clip.
    struct Clip {
        let duration: TimeInterval
        /// Average power in dBFS: ~ -160 (digital silence) ... 0 (full scale).
        let averagePower: Float
    }

    /// Decode the recorded file and measure how long and how loud it is, so a
    /// near-silent or ultra-short clip can be dropped before transcription
    /// (Whisper invents filler — "you", "ご視聴ありがとうございました" — on silence).
    /// Returns nil if the file can't be read; callers should then proceed
    /// (fail open) rather than discard a possibly-valid recording.
    static func inspect(url: URL) -> Clip? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? file.read(into: buffer)) != nil,
              let channelData = buffer.floatChannelData
        else { return nil }

        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        let duration = format.sampleRate > 0 ? Double(frameCount) / format.sampleRate : 0
        guard frames > 0, channels > 0 else { return Clip(duration: duration, averagePower: -160) }

        var sumSquares = 0.0
        for ch in 0..<channels {
            let samples = channelData[ch]
            for i in 0..<frames {
                let s = Double(samples[i])
                sumSquares += s * s
            }
        }
        let rms = sqrt(sumSquares / Double(frames * channels))
        let power: Float = rms > 0 ? 20 * log10(Float(rms)) : -160
        return Clip(duration: duration, averagePower: power)
    }
}
