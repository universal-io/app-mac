import Foundation
import SQLite3

extension Notification.Name {
    /// Posted after any local write to `memory_cards` (persona/relationship
    /// create, edit, or delete). `MemorySyncService` debounces on this to
    /// push the change to the gateway. Never posted by `applyServerState`,
    /// since that would re-trigger the sync loop.
    static let memoryCardsDidChange = Notification.Name("BombSquad.memoryCardsDidChange")
}

/// Local persistence for memory cards (persona / relationship), following the
/// same SQLite pattern as `LocalHistoryStore`. Stored in its own database so
/// history and memory can evolve (and sync, in M3) independently. The schema
/// mirrors the server-side `bs_memory_cards` table synced via
/// `MemorySyncService` (`GET/PUT /api/memory/cards`, docs/api-contract.md).
actor MemoryStore {
    static let shared = MemoryStore()

    private var database: OpaquePointer?
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    deinit {
        sqlite3_close(database)
    }

    // MARK: - Persona

    /// The single persona card, if one exists (bootstrap or auto-created).
    func personaCard() throws -> MemoryCard? {
        try fetchCards(kind: .persona).first
    }

    /// Create or replace the persona card content.
    func savePersona(contentMD: String, source: MemoryCard.Source) throws {
        if let existing = try personaCard() {
            try updateCard(id: existing.id, contentMD: contentMD, source: source)
        } else {
            try insertCard(kind: .persona, subject: nil, contentMD: contentMD, source: source)
            postChangeNotification()
        }
    }

    /// Append a distilled note to the persona card, creating a provisional
    /// card when none exists yet. Skipped when the card has grown past the
    /// size cap (re-distillation into a compact card is a later milestone).
    func appendPersonaNote(_ note: String) throws {
        let dateStamp = Self.dateStamp()
        if let existing = try personaCard() {
            guard existing.contentMD.count < Self.maxCardChars else { return }
            var content = existing.contentMD
            if !content.contains(Self.learnedSectionHeader) {
                content += "\n\n\(Self.learnedSectionHeader)\n"
            }
            content += "- \(dateStamp): \(note)\n"
            try updateCard(id: existing.id, contentMD: content, source: .distilled)
        } else {
            let content = """
            # スタイルプロファイル（自動学習・暫定）

            まだブートストラップが行われていないため、使用中の学習だけで作られた暫定プロファイルです。

            \(Self.learnedSectionHeader)
            - \(dateStamp): \(note)
            """
            try insertCard(kind: .persona, subject: nil, contentMD: content, source: .distilled)
            postChangeNotification()
        }
    }

    // MARK: - Relationships

    func relationshipCards() throws -> [MemoryCard] {
        try fetchCards(kind: .relationship)
    }

    /// Append a distilled note to the card for `subject`, creating it on first
    /// encounter.
    func appendRelationshipNote(subject: String, note: String) throws {
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSubject.isEmpty else { return }
        let dateStamp = Self.dateStamp()

        if let existing = try relationshipCards().first(where: {
            $0.subject?.compare(trimmedSubject, options: .caseInsensitive) == .orderedSame
        }) {
            guard existing.contentMD.count < Self.maxCardChars else { return }
            let content = existing.contentMD + "\n- \(dateStamp): \(note)"
            try updateCard(id: existing.id, contentMD: content, source: .distilled)
        } else {
            let content = """
            # \(trimmedSubject)

            - \(dateStamp): \(note)
            """
            try insertCard(kind: .relationship, subject: trimmedSubject, contentMD: content, source: .distilled)
            postChangeNotification()
        }
    }

    /// Find the relationship card whose subject appears in the given text
    /// (window title + conversation excerpt). Case-insensitive contains match;
    /// good enough until embeddings arrive in M3.
    func matchRelationship(inText text: String) throws -> MemoryCard? {
        guard !text.isEmpty else { return nil }
        let haystack = text.lowercased()
        return try relationshipCards().first { card in
            guard let subject = card.subject?.lowercased(), subject.count >= 2 else { return false }
            return haystack.contains(subject)
        }
    }

    // MARK: - Generic card operations

    func updateCard(id: String, contentMD: String, source: MemoryCard.Source) throws {
        try openIfNeeded()
        let sql = "UPDATE memory_cards SET content_md = ?, source = ?, updated_at = ? WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, contentMD, -1, transientDestructor)
        sqlite3_bind_text(statement, 2, source.rawValue, -1, transientDestructor)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 4, id, -1, transientDestructor)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        postChangeNotification()
    }

    /// Soft delete: marks the row as a tombstone (`deleted_at` + bumped
    /// `updated_at`) instead of removing it, so the sync merge can propagate
    /// the deletion to other devices.
    func deleteCard(id: String) throws {
        try openIfNeeded()
        let sql = "UPDATE memory_cards SET deleted_at = ?, updated_at = ? WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        sqlite3_bind_double(statement, 1, now)
        sqlite3_bind_double(statement, 2, now)
        sqlite3_bind_text(statement, 3, id, -1, transientDestructor)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        postChangeNotification()
    }

    /// Hard wipe of every row, tombstones included. Used only by the "reset
    /// memory entirely" developer/debug path, never by normal card deletion.
    func deleteAll() throws {
        try openIfNeeded()
        try execute("DELETE FROM memory_cards;")
    }

    // MARK: - Sync (M3-B)

    /// Every local card, including soft-deleted tombstones — the full state
    /// pushed to the gateway on each sync.
    func allCardsIncludingDeleted() throws -> [MemoryCard] {
        try openIfNeeded()
        let sql = """
        SELECT id, kind, subject, content_md, source, created_at, updated_at, deleted_at
        FROM memory_cards
        ORDER BY updated_at DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }

        var cards: [MemoryCard] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let card = card(from: statement) {
                cards.append(card)
            }
        }
        return cards
    }

    /// Applies the gateway's merged server state (the `PUT` response body)
    /// back into the local store: inserts cards missing locally, and
    /// overwrites a local row only when the server copy is strictly newer
    /// (last-write-wins on `updatedAt`). Never posts `.memoryCardsDidChange`
    /// — this is the pull side of sync, not a user edit, and posting would
    /// re-trigger `MemorySyncService`'s debounced push.
    func applyServerState(_ cards: [MemoryCard]) throws {
        try openIfNeeded()
        let localByID = Dictionary(
            uniqueKeysWithValues: try allCardsIncludingDeleted().map { ($0.id, $0) }
        )
        for card in cards {
            if let local = localByID[card.id] {
                guard card.updatedAt > local.updatedAt else { continue }
            }
            try upsertCard(card)
        }
    }

    // MARK: - Internals

    private static let learnedSectionHeader = "## 学習した傾向"
    private static let maxCardChars = 6000

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func postChangeNotification() {
        NotificationCenter.default.post(name: .memoryCardsDidChange, object: nil)
    }

    private func fetchCards(kind: MemoryCard.Kind) throws -> [MemoryCard] {
        try openIfNeeded()
        let sql = """
        SELECT id, kind, subject, content_md, source, created_at, updated_at, deleted_at
        FROM memory_cards
        WHERE kind = ? AND deleted_at IS NULL
        ORDER BY updated_at DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, transientDestructor)

        var cards: [MemoryCard] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let card = card(from: statement) {
                cards.append(card)
            }
        }
        return cards
    }

    /// Parses one row from a `SELECT id, kind, subject, content_md, source,
    /// created_at, updated_at, deleted_at` statement.
    private func card(from statement: OpaquePointer?) -> MemoryCard? {
        guard
            let id = string(from: statement, column: 0),
            let kindString = string(from: statement, column: 1),
            let kind = MemoryCard.Kind(rawValue: kindString),
            let contentMD = string(from: statement, column: 3),
            let sourceString = string(from: statement, column: 4),
            let source = MemoryCard.Source(rawValue: sourceString)
        else { return nil }

        let deletedAt: Date? = sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))

        return MemoryCard(
            id: id,
            kind: kind,
            subject: string(from: statement, column: 2),
            contentMD: contentMD,
            source: source,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            deletedAt: deletedAt
        )
    }

    private func insertCard(
        kind: MemoryCard.Kind,
        subject: String?,
        contentMD: String,
        source: MemoryCard.Source
    ) throws {
        try openIfNeeded()
        let sql = """
        INSERT INTO memory_cards (id, kind, subject, content_md, source, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }

        let now = Date().timeIntervalSince1970
        // Lowercase to match Postgres' uuid canonical form. The sync merge
        // and SQLite's PRIMARY KEY both compare ids as case-sensitive text, so
        // a mixed-case id and its lowercased server echo would be treated as
        // two distinct cards and the row would duplicate on every round trip.
        sqlite3_bind_text(statement, 1, UUID().uuidString.lowercased(), -1, transientDestructor)
        sqlite3_bind_text(statement, 2, kind.rawValue, -1, transientDestructor)
        if let subject {
            sqlite3_bind_text(statement, 3, subject, -1, transientDestructor)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, contentMD, -1, transientDestructor)
        sqlite3_bind_text(statement, 5, source.rawValue, -1, transientDestructor)
        sqlite3_bind_double(statement, 6, now)
        sqlite3_bind_double(statement, 7, now)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    /// Inserts a card as-is (server id, timestamps, and tombstone state
    /// preserved), or overwrites an existing row's mutable fields on
    /// conflict. `created_at` is intentionally left out of the `DO UPDATE
    /// SET` clause so the locally-recorded creation time is never clobbered
    /// by a merge.
    private func upsertCard(_ card: MemoryCard) throws {
        try openIfNeeded()
        let sql = """
        INSERT INTO memory_cards (id, kind, subject, content_md, source, created_at, updated_at, deleted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            subject = excluded.subject,
            content_md = excluded.content_md,
            source = excluded.source,
            updated_at = excluded.updated_at,
            deleted_at = excluded.deleted_at;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, card.id, -1, transientDestructor)
        sqlite3_bind_text(statement, 2, card.kind.rawValue, -1, transientDestructor)
        if let subject = card.subject {
            sqlite3_bind_text(statement, 3, subject, -1, transientDestructor)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, card.contentMD, -1, transientDestructor)
        sqlite3_bind_text(statement, 5, card.source.rawValue, -1, transientDestructor)
        sqlite3_bind_double(statement, 6, card.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, card.updatedAt.timeIntervalSince1970)
        if let deletedAt = card.deletedAt {
            sqlite3_bind_double(statement, 8, deletedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 8)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func openIfNeeded() throws {
        guard database == nil else { return }

        let directoryURL = try applicationSupportDirectory()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let databaseURL = directoryURL.appendingPathComponent("memory.sqlite")
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            if let db {
                sqlite3_close(db)
            }
            throw databaseError(database: db)
        }

        database = db
        try execute(
            """
            CREATE TABLE IF NOT EXISTS memory_cards (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                subject TEXT,
                content_md TEXT NOT NULL,
                source TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                deleted_at REAL
            );
            """
        )
        try migrateAddDeletedAtColumnIfNeeded()
        try migrateNormalizeIdCaseIfNeeded()
    }

    /// Repairs rows created before ids were lowercased (see `insertCard`).
    /// An uppercase-id card and its lowercased server echo could coexist as
    /// duplicates; drop the uppercase row when its lowercased twin already
    /// exists (the server echo is the newest state), then lowercase any
    /// remaining uppercase ids so future merges collapse onto one row.
    private func migrateNormalizeIdCaseIfNeeded() throws {
        try execute(
            """
            DELETE FROM memory_cards
             WHERE id <> lower(id)
               AND lower(id) IN (SELECT id FROM memory_cards WHERE id = lower(id));
            UPDATE memory_cards SET id = lower(id) WHERE id <> lower(id);
            """
        )
    }

    /// Adds `deleted_at` to databases created before sync support (M3-B).
    /// SQLite has no `ADD COLUMN IF NOT EXISTS`, so existence is checked via
    /// `PRAGMA table_info` first. A no-op for fresh databases, whose
    /// `CREATE TABLE` above already declares the column.
    private func migrateAddDeletedAtColumnIfNeeded() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(memory_cards);", -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        var hasDeletedAt = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if string(from: statement, column: 1) == "deleted_at" {
                hasDeletedAt = true
                break
            }
        }
        sqlite3_finalize(statement)

        guard !hasDeletedAt else { return }
        try execute("ALTER TABLE memory_cards ADD COLUMN deleted_at REAL;")
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func string(from statement: OpaquePointer?, column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    private func applicationSupportDirectory() throws -> URL {
        try AppSupport.directory()
    }

    private func databaseError(database: OpaquePointer? = nil) -> NSError {
        let db = database ?? self.database
        let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "Unknown SQLite error"
        return NSError(domain: "MemoryStore", code: Int(sqlite3_errcode(db)), userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

    private var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
    }
}
