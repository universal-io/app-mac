import Foundation

/// R18 (requirements R12): what the companion says while it looks. The Live
/// model stays silent while a tool runs — "確認しますね" cannot be left to it
/// (POC journal) — so the client plays one of these the moment look_closely
/// is called. Recorded once with Gemini TTS in the Live voice (Zephyr,
/// gemini-3.8-flash-tts, 2026-10-08); a TTS voice is close to, not the same
/// as, the Live one.
///
/// Played through `CompanionAudio`, like the model's voice, so the voice
/// processor takes it out of the microphone too.
enum CompanionBridge {
    /// 24 kHz mono PCM16 LE, one per phrase.
    static let clips: [Data] = (1...3).compactMap { index in
        Bundle.main.url(forResource: "companion-bridge-\(index)", withExtension: "wav")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { pcm16(fromWAV: $0) }
    }

    private static var lastIndex = -1

    /// A different phrase from the last one, when there is more than one.
    static func next() -> Data? {
        guard !clips.isEmpty else { return nil }
        var index = Int.random(in: 0..<clips.count)
        if clips.count > 1, index == lastIndex { index = (index + 1) % clips.count }
        lastIndex = index
        return clips[index]
    }

    /// The samples of a 16-bit mono 24 kHz WAV, or nil for anything else.
    static func pcm16(fromWAV data: Data) -> Data? {
        guard data.count > 12,
              data.prefix(4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8)
        else { return nil }
        var offset = 12
        var formatOK = false
        while offset + 8 <= data.count {
            let id = data.subdata(in: offset..<(offset + 4))
            let size = Int(data.littleEndianUInt32(at: offset + 4))
            let body = offset + 8
            guard body + size <= data.count else { return nil }
            if id == Data("fmt ".utf8), size >= 16 {
                let format = data.littleEndianUInt16(at: body)
                let channels = data.littleEndianUInt16(at: body + 2)
                let rate = data.littleEndianUInt32(at: body + 4)
                let bits = data.littleEndianUInt16(at: body + 14)
                formatOK = format == 1 && channels == 1 && rate == 24_000 && bits == 16
            } else if id == Data("data".utf8) {
                return formatOK ? data.subdata(in: body..<(body + size)) : nil
            }
            offset = body + size + (size % 2)
        }
        return nil
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
}
