import Foundation

/// A single durable memory: either the user's own style profile (persona,
/// L3) or a per-contact relationship note (L2). Cards are plain Markdown so
/// the user can read and edit everything the app knows about them — the
/// memory page is a transparency feature, not just storage.
///
/// `Codable` with snake_case coding keys matches the Gateway wire format for
/// memory sync (`GET/PUT /api/memory/cards`, docs/api-contract.md). Callers
/// that encode/decode over the wire must set `.secondsSince1970` as the
/// date strategy, since the server (and the local SQLite `REAL` column)
/// both use epoch seconds.
struct MemoryCard: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case persona
        case relationship
    }

    /// Where the current content came from. `userEdited` wins conceptually:
    /// distillation appends but never rewrites what the user wrote.
    enum Source: String, Codable {
        case bootstrap
        case distilled
        case userEdited = "user_edited"
    }

    let id: String
    let kind: Kind
    /// Display name of the contact for relationship cards; nil for persona.
    let subject: String?
    var contentMD: String
    var source: Source
    let createdAt: Date
    var updatedAt: Date
    /// Soft-delete tombstone timestamp; nil while the card is live. Rows are
    /// retained without subject/content so a long-offline device cannot
    /// resurrect a deletion. Incremental sync avoids resending clean rows.
    var deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, kind, subject
        case contentMD = "content_md"
        case source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

/// Memory selected for injection into one review call: the persona card plus
/// the relationship card matched against the situational context.
struct MemoryInjection {
    let personaMD: String?
    let relationshipSubject: String?
    let relationshipMD: String?

    var isEmpty: Bool { personaMD == nil && relationshipMD == nil }
}
