import Foundation

/// Speech-to-text abstraction: the gateway proxy is the production path,
/// the BYOK Groq client remains as a developer fallback.
protocol Transcriber {
    func transcribe(fileURL: URL) async throws -> String
}

/// ASR via the product gateway (POST /api/ai/transcribe). The server owns the
/// Groq key and the hallucination filter; usage is metered per tenant.
struct GatewayTranscriber: Transcriber {
    private let client: GatewayClient

    static func make() -> GatewayTranscriber? {
        EngineResolver.gateway().map(GatewayTranscriber.init)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    func transcribe(fileURL: URL) async throws -> String {
        let audioData = try Data(contentsOf: fileURL)

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = try await client.authorizedRequest("ai/transcribe")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, audioData: audioData)

        let data = try await client.send(request)

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        let client = GatewayClient.clientPayload()
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
