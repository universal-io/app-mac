import Foundation

/// Speech-to-text abstraction implemented by the production Gateway.
protocol Transcriber {
    func transcribe(fileURL: URL) async throws -> String
}

/// ASR via the product gateway (POST /api/ai/transcribe). The server owns the
/// Groq key and the hallucination filter; usage is metered per tenant.
/// Transport/error plumbing lives in `GatewayClient`.
struct GatewayTranscriber: Transcriber {
    private let client: GatewayClient

    static func make() -> GatewayTranscriber? {
        guard let client = GatewayClient.make() else { return nil }
        return GatewayTranscriber(client: client)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    static func warmUp() async {
        guard let client = GatewayClient.make() else { return }
        _ = try? await client.get("ai/transcribe")
    }

    func transcribe(fileURL: URL) async throws -> String {
        let totalStarted = ContinuousClock.now
        let audioData = try Data(contentsOf: fileURL)
        let boundary = "Boundary-\(UUID().uuidString)"
        let data = try await client.postMultipart(
            "ai/transcribe",
            boundary: boundary,
            body: multipartBody(
                boundary: boundary,
                audioData: audioData,
                fileExtension: fileURL.pathExtension.lowercased()
            )
        )

        let root = try GatewayClient.rootObject(data)
        guard
            let result = root["result"] as? [String: Any],
            let text = result["text"] as? String
        else {
            throw ProviderError.decoding("unexpected gateway response shape")
        }
        let elapsed = totalStarted.duration(to: .now)
        #if DEBUG
        NSLog(
            "[TranscriptionTrace] totalMs=%d bytes=%d",
            Int(elapsed.components.seconds * 1_000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000),
            audioData.count
        )
        #endif
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func multipartBody(
        boundary: String,
        audioData: Data,
        fileExtension: String
    ) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        let client = GatewayAPI.clientPayload()
        field("request_id", UUID().uuidString)
        field("platform", client["platform"] as? String ?? "macos")
        field("app_version", client["app_version"] as? String ?? "0")
        field("language", AppSettings.outputLanguage() == .japanese ? "ja" : "en")

        let isWAV = fileExtension == "wav"
        let filename = isWAV ? "audio.wav" : "audio.m4a"
        let contentType = isWAV ? "audio/wav" : "audio/m4a"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
