import Foundation

/// Client for the user-fact store (`/api/facts`). The gateway owns both the
/// values and the vocabulary they may use, so this client never decides what a
/// fact is called or which keys exist — adding a tool must not require touching
/// the Mac app.
///
/// The whole set is a few dozen rows, so every read is a full pull and every
/// write is one key. No cursor, no merge, no local mirror.
struct GatewayFactsClient {
    private let client: GatewayClient

    static func make() -> GatewayFactsClient? {
        guard let client = GatewayClient.make() else { return nil }
        return GatewayFactsClient(client: client)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    func fetchFacts() async throws -> (facts: [UserFact], maxValueChars: Int) {
        let data = try await client.get("facts")
        let envelope: FactsResponse
        do {
            envelope = try JSONDecoder().decode(FactsResponse.self, from: data)
        } catch {
            throw ProviderError.decoding("facts response: \(error.localizedDescription)")
        }
        return (envelope.facts.map(\.asUserFact), envelope.maxValueChars)
    }

    func save(scope: String, key: String, value: String) async throws {
        _ = try await client.postJSON(
            "facts",
            method: "PUT",
            body: ["scope": scope, "key": key, "value": value]
        )
    }

    func delete(scope: String, key: String) async throws {
        _ = try await client.postJSON(
            "facts",
            method: "DELETE",
            body: ["scope": scope, "key": key]
        )
    }
}

private struct FactsResponse: Decodable {
    struct Fact: Decodable {
        let scope: String
        let scopeLabel: String
        let key: String
        let label: String
        let value: String?
        let updatedAt: String?

        var asUserFact: UserFact {
            UserFact(
                scope: scope,
                scopeLabel: scopeLabel,
                key: key,
                label: label,
                value: value,
                updatedAt: updatedAt.flatMap(FactsResponse.timestamp(from:))
            )
        }
    }

    let facts: [Fact]
    let maxValueChars: Int

    private enum CodingKeys: String, CodingKey {
        case facts
        case maxValueChars = "max_value_chars"
    }

    static func timestamp(from raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}

private extension FactsResponse.Fact {
    enum CodingKeys: String, CodingKey {
        case scope
        case scopeLabel = "scope_label"
        case key
        case label
        case value
        case updatedAt = "updated_at"
    }
}
