import AppKit
import Foundation

/// One proactive compose suggestion produced from the pre-captured screen.
struct ComposeSuggestion: Equatable {
    let captureID: UUID
    /// The proposed text for the currently focused input field. Empty when the
    /// model could not responsibly propose anything.
    let draft: String
    /// One short Japanese sentence describing what was detected / proposed.
    let note: String
    /// Display name of the skill the gateway applied, or nil when no skill
    /// matched the screen. Shown in the panel: a skill never acts silently.
    let skillName: String?
    /// At most one fact to confirm with the user, or nil. Detection rides along
    /// with the draft — there is no separate call and no extra latency for it.
    let factQuestion: FactQuestion?
}

/// Gateway-backed client for `POST /ai/suggest`. Mirrors `GatewayVisionClient`:
/// no provider keys on device, the server owns the prompt and model routing,
/// and the immutable capture is sent as base64. Transport lives in
/// `GatewayClient`.
struct GatewaySuggestClient {
    private static let maxRawImageBytes = 3_000_000

    private let client: GatewayClient

    static func make() -> GatewaySuggestClient? {
        guard let client = GatewayClient.make() else { return nil }
        return GatewaySuggestClient(client: client)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    func suggest(
        attachment: ScreenshotAttachment,
        context: SituationalContext?,
        language: OutputLanguage
    ) async throws -> ComposeSuggestion {
        let encoded = try Self.encodedImage(at: attachment.url)
        var inputPayload: [String: Any] = [
            "capture_id": attachment.id.uuidString,
            "image_base64": encoded.data.base64EncodedString(),
            "media_type": encoded.mediaType,
        ]
        if let context {
            inputPayload["context"] = GatewayClient.contextPayload(context)
        }

        let body = GatewayClient.envelope(
            operation: "suggest",
            input: inputPayload,
            language: language
        )
        let data = try await client.postJSON(
            "ai/suggest",
            body: body,
            timeout: OperationDeadline.suggestRequest
        )
        return try Self.decode(data, expectedCaptureID: attachment.id)
    }

    private static func encodedImage(at url: URL) throws -> (data: Data, mediaType: String) {
        let source = try Data(contentsOf: url)
        guard source.count > maxRawImageBytes else {
            return (source, url.pathExtension.lowercased() == "jpg" ? "image/jpeg" : "image/png")
        }
        guard
            let bitmap = NSBitmapImageRep(data: source),
            let jpeg = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.9]
            )
        else {
            throw ProviderError.decoding("The captured image exceeds the Gateway limit.")
        }
        return (jpeg, "image/jpeg")
    }

    private static func decode(
        _ data: Data,
        expectedCaptureID: UUID
    ) throws -> ComposeSuggestion {
        let root = try GatewayClient.rootObject(data)
        guard
            let rawCaptureID = root["capture_id"] as? String,
            let captureID = UUID(uuidString: rawCaptureID),
            captureID == expectedCaptureID,
            let result = root["result"] as? [String: Any],
            let draft = result["draft"] as? String,
            let note = result["note"] as? String
        else {
            throw ProviderError.decoding("The suggestion response did not match its contract.")
        }
        let skill = result["skill"] as? [String: Any]
        return ComposeSuggestion(
            captureID: captureID,
            draft: draft.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            skillName: (skill?["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilWhenEmpty,
            factQuestion: factQuestion(from: result["fact_question"])
        )
    }

    /// A malformed question is dropped rather than failing the whole response:
    /// the draft is the reason this call was made, and losing it over an
    /// optional side task would be the wrong trade every time.
    private static func factQuestion(from raw: Any?) -> FactQuestion? {
        guard
            let payload = raw as? [String: Any],
            let scope = (payload["scope"] as? String)?.nilWhenEmpty,
            let key = (payload["key"] as? String)?.nilWhenEmpty,
            let value = (payload["value"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilWhenEmpty,
            let question = (payload["question"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilWhenEmpty
        else { return nil }
        return FactQuestion(scope: scope, key: key, value: value, question: question)
    }
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
