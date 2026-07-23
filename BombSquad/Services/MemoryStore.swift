import Foundation
import SQLite3

extension Notification.Name {
    /// Posted after any local write to `memory_cards` (persona/relationship
    /// create, edit, or delete). `MemorySyncService` debounces on this to
    /// push the change to the gateway. Server reconciliation does not post it,
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
    private var activeUserID: UUID?
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    deinit {
        sqlite3_close(database)
    }

    func activateAccount(userID: UUID?, migrateLegacyDatabase: Bool = false) throws {
        if activeUserID == userID { return }
        sqlite3_close(database)
        database = nil
        activeUserID = userID
        if let userID {
            _ = try AppSupport.accountDirectory(
                for: userID,
                migrateLegacyDatabases: migrateLegacyDatabase
            )
        }
        NotificationCenter.default.post(name: .memoryCardsDidSync, object: nil)
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
    /// card when none exists yet. The auto-learned section is deduplicated and
    /// bounded independently from the user-controlled profile text.
    func appendPersonaNote(_ note: String) throws {
        if let existing = try personaCard() {
            guard let content = Self.appendingLearnedNote(note, to: existing.contentMD) else {
                return
            }
            try updateCard(id: existing.id, contentMD: content, source: .distilled)
        } else {
            let content = """
            # スタイルプロファイル（自動学習・暫定）

            まだブートストラップが行われていないため、使用中の学習だけで作られた暫定プロファイルです。

            \(Self.learnedSectionHeader)
            - \(Self.dateStamp()): \(note)
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

        let normalizedSubject = Self.normalizedRelationshipSubject(trimmedSubject)
        let relationships = try relationshipCards()
        if let existing = relationships.first(where: {
            guard let subject = $0.subject else { return false }
            return Self.normalizedRelationshipSubject(subject) == normalizedSubject
        }) {
            guard let content = Self.appendingLearnedNote(note, to: existing.contentMD) else {
                return
            }
            try updateCard(id: existing.id, contentMD: content, source: .distilled)
        } else {
            // One persona plus at most 199 live relationship cards. Deleted
            // tombstones are not part of this product limit and incremental
            // sync no longer sends them on every request.
            guard relationships.count < 199 else { return }
            let content = """
            # \(trimmedSubject)

            \(Self.learnedSectionHeader)
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
        let sql = """
        UPDATE memory_cards
        SET content_md = ?, source = ?, updated_at = ?, sync_state = 'dirty'
        WHERE id = ?;
        """
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

    /// Soft delete: keep only a content-free tombstone so the sync merge can
    /// propagate deletion to other devices without retaining the user's text.
    func deleteCard(id: String) throws {
        try openIfNeeded()
        let sql = """
        UPDATE memory_cards
        SET subject = NULL, content_md = '', deleted_at = ?, updated_at = ?, sync_state = 'dirty'
        WHERE id = ?;
        """
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

    /// Every local card, including soft-deleted tombstones. Kept for local
    /// inspection and one-time database migration; normal sync sends only
    /// rows whose `sync_state` is dirty.
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

    /// Returns one bounded batch of local changes. `baseServerUpdatedAt` is
    /// the server version the edit was based on, so the gateway can reject a
    /// true cross-device conflict without trusting the Mac's wall clock.
    func pendingSyncRecords(limit: Int = 100) throws -> [MemoryUploadRecord] {
        try openIfNeeded()
        let sql = """
        SELECT id, kind, subject, content_md, source, created_at, updated_at, deleted_at,
               server_updated_at
        FROM memory_cards
        WHERE sync_state IN ('dirty', 'conflict')
        ORDER BY updated_at ASC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var records: [MemoryUploadRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let card = card(from: statement) else { continue }
            let base = sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            records.append(MemoryUploadRecord(card: card, baseServerUpdatedAt: base))
        }
        return records
    }

    func syncCursor() throws -> Date? {
        try openIfNeeded()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM memory_sync_state WHERE key = 'cursor';",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = string(from: statement, column: 0),
              let seconds = TimeInterval(value)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Applies an incremental server page. Dirty rows are never overwritten
    /// unless the server explicitly acknowledged that exact local upload.
    func applySyncResponse(_ response: MemorySyncResponse) throws {
        try openIfNeeded()
        let acknowledged = Set(response.syncedIDs)
        for remote in response.cards {
            if let state = try syncState(for: remote.id),
               state == "dirty" || state == "conflict",
               !acknowledged.contains(remote.id) {
                continue
            }
            try upsertCard(remote)
            try markClean(id: remote.id, serverUpdatedAt: remote.updatedAt)
        }

        for conflict in response.conflicts {
            try markConflict(id: conflict.id)
        }

        if let cursor = response.cursor {
            try execute(
                """
                INSERT INTO memory_sync_state (key, value)
                VALUES ('cursor', '\(cursor.timeIntervalSince1970)')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """
            )
        }
    }

    /// Explicit conflict resolution: preserve this Mac's edit, but rebase it
    /// onto the server version returned with the conflict. The next sync can
    /// then overwrite intentionally instead of doing so silently.
    func resolveConflictsUsingLocal(_ serverCards: [MemoryCard]) throws {
        try openIfNeeded()
        for card in serverCards {
            let sql = """
            UPDATE memory_cards
            SET server_updated_at = ?, sync_state = 'dirty'
            WHERE id = ? AND sync_state = 'conflict';
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError()
            }
            sqlite3_bind_double(statement, 1, card.updatedAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, card.id, -1, transientDestructor)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw databaseError()
            }
            sqlite3_finalize(statement)
        }
    }

    /// Explicit conflict resolution: discard this Mac's edit and apply the
    /// already-current cloud copy supplied by the gateway.
    func resolveConflictsUsingCloud(_ serverCards: [MemoryCard]) throws {
        try openIfNeeded()
        for card in serverCards {
            try upsertCard(card)
            try markClean(id: card.id, serverUpdatedAt: card.updatedAt)
        }
        NotificationCenter.default.post(name: .memoryCardsDidSync, object: nil)
    }

    // MARK: - Internals

    private static let learnedSectionHeader = "## 学習した傾向"
    private static let maxCardChars = 6000
    private static let maxLearnedNotes = 20

    private static func normalizedRelationshipSubject(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Appends one unique auto-learned note while keeping the learned section
    /// bounded. Text before the section is user-controlled and never trimmed.
    private static func appendingLearnedNote(_ note: String, to content: String) -> String? {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty,
              !content.localizedCaseInsensitiveContains(trimmedNote)
        else { return nil }

        let prefix: String
        let learnedText: String
        if let marker = content.range(of: learnedSectionHeader) {
            prefix = String(content[..<marker.upperBound])
            learnedText = String(content[marker.upperBound...])
        } else {
            prefix = content.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n\(learnedSectionHeader)"
            learnedText = ""
        }

        let existingNotes = learnedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
        var notes = Array(
            (existingNotes + ["- \(dateStamp()): \(trimmedNote)"])
                .suffix(maxLearnedNotes)
        )

        while !notes.isEmpty {
            let candidate = prefix + "\n" + notes.joined(separator: "\n") + "\n"
            if candidate.count <= maxCardChars {
                return candidate
            }
            notes.removeFirst()
        }
        return nil
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
        INSERT INTO memory_cards (
            id, kind, subject, content_md, source, created_at, updated_at, sync_state
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'dirty');
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

        guard let activeUserID else { throw LocalAccountDataError.noActiveAccount }
        let directoryURL = try AppSupport.accountDirectory(for: activeUserID)
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
                deleted_at REAL,
                server_updated_at REAL,
                sync_state TEXT NOT NULL DEFAULT 'dirty'
            );
            """
        )
        try migrateAddDeletedAtColumnIfNeeded()
        try migrateAddSyncColumnsIfNeeded()
        try execute(
            """
            CREATE TABLE IF NOT EXISTS memory_sync_state (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """
        )
        try migrateNormalizeIdCaseIfNeeded()
        try scrubDeletedCardContent()
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

    private func migrateAddSyncColumnsIfNeeded() throws {
        let columns = try tableColumns("memory_cards")
        if !columns.contains("server_updated_at") {
            // Existing clients used the same updated_at value on the server.
            // Treat it as the initial base version; the first successful new
            // protocol sync replaces it with an authoritative server clock.
            try execute("ALTER TABLE memory_cards ADD COLUMN server_updated_at REAL;")
            try execute("UPDATE memory_cards SET server_updated_at = updated_at;")
        }
        if !columns.contains("sync_state") {
            try execute("ALTER TABLE memory_cards ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'dirty';")
        }
    }

    private func tableColumns(_ table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = string(from: statement, column: 1) { result.insert(name) }
        }
        return result
    }

    private func syncState(for id: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT sync_state FROM memory_cards WHERE id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, transientDestructor)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return string(from: statement, column: 0)
    }

    private func markClean(id: String, serverUpdatedAt: Date) throws {
        let sql = """
        UPDATE memory_cards
        SET server_updated_at = ?, sync_state = 'clean'
        WHERE id = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, serverUpdatedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, id, -1, transientDestructor)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func markConflict(id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "UPDATE memory_cards SET sync_state = 'conflict' WHERE id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, transientDestructor)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    /// Older builds retained card content inside deletion tombstones. Scrub
    /// it on first access without changing the logical deletion timestamp.
    private func scrubDeletedCardContent() throws {
        try execute(
            """
            UPDATE memory_cards
            SET subject = NULL, content_md = ''
            WHERE deleted_at IS NOT NULL
              AND (subject IS NOT NULL OR content_md <> '');
            """
        )
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
