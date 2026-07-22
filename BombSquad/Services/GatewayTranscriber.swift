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

    func transcribe(fileURL: URL) async throws -> String {
        let audioData = try Data(contentsOf: fileURL)
        let boundary = "Boundary-\(UUID().uuidString)"
        let data = try await client.postMultipart(
            "ai/transcribe",
            boundary: boundary,
            body: multipartBody(boundary: boundary, audioData: audioData)
        )

        let root = try GatewayClient.rootObject(data)
        guard
            let result = root["result"] as? [String: Any],
            let text = result["text"] as? String
        else {
            throw ProviderError.decoding("unexpected gateway response shape")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func multipartBody(boundary: String, audioData: Data) -> Data {
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

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
