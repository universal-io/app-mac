import Foundation
import SQLite3

protocol HistoryStore: Sendable {
    func record(_ entry: HistoryEntryInput) async
    func fetchEntries(limit: Int) async throws -> [HistoryEntry]
    func clear() async throws
}

actor LocalHistoryStore: HistoryStore {
    static let shared = LocalHistoryStore()

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
    }

    func record(_ entry: HistoryEntryInput) async {
        guard AppSettings.isHistoryEnabled() else { return }
        do {
            try openIfNeeded()
            try insert(entry)
            try prune(limit: AppSettings.localHistoryLimit)
        } catch {
            NSLog("BombSquad history record failed: \(error.localizedDescription)")
        }
    }

    func fetchEntries(limit: Int = AppSettings.localHistoryLimit) async throws -> [HistoryEntry] {
        try openIfNeeded()

        let sql = """
        SELECT id, created_at, source_text, final_text, model_id, model_name, output_language
        FROM history_entries
        WHERE mode = 'compose' AND action = 'sent'
        ORDER BY created_at DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var entries: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idString = string(from: statement, column: 0),
                let id = UUID(uuidString: idString),
                let sourceText = string(from: statement, column: 2),
                let finalText = string(from: statement, column: 3)
            else {
                continue
            }

            entries.append(
                HistoryEntry(
                    id: id,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    sourceText: sourceText,
                    finalText: finalText,
                    modelID: string(from: statement, column: 4),
                    modelName: string(from: statement, column: 5),
                    outputLanguage: string(from: statement, column: 6)
                )
            )
        }

        return entries
    }

    func clear() async throws {
        try openIfNeeded()
        try execute("DELETE FROM history_entries;")
    }

    private func openIfNeeded() throws {
        guard database == nil else { return }

        guard let activeUserID else { throw LocalAccountDataError.noActiveAccount }
        let directoryURL = try AppSupport.accountDirectory(for: activeUserID)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let databaseURL = directoryURL.appendingPathComponent("history.sqlite")
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            if let db {
                sqlite3_close(db)
            }
            throw databaseError(database: db)
        }

        database = db
        try migrate()
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS history_entries (
                id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL,
                mode TEXT NOT NULL,
                source_text TEXT NOT NULL,
                final_text TEXT NOT NULL,
                model_id TEXT,
                model_name TEXT,
                output_language TEXT,
                action TEXT NOT NULL
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS history_entries_created_at_idx
            ON history_entries(created_at DESC);
            """
        )
        // Remove non-send rows created by older versions and keep the local
        // history contract Compose-only.
        try execute("DELETE FROM history_entries WHERE mode <> 'compose' OR action <> 'sent';")
    }

    private func insert(_ entry: HistoryEntryInput) throws {
        let sql = """
        INSERT INTO history_entries (
            id, created_at, mode, source_text, final_text, model_id, model_name, output_language, action
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }

        let recordID = UUID().uuidString
        sqlite3_bind_text(statement, 1, recordID, -1, transientDestructor)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, "compose", -1, transientDestructor)
        sqlite3_bind_text(statement, 4, entry.sourceText, -1, transientDestructor)
        sqlite3_bind_text(statement, 5, entry.finalText, -1, transientDestructor)
        bindOptionalText(entry.modelID, statement: statement, column: 6)
        bindOptionalText(entry.modelName, statement: statement, column: 7)
        bindOptionalText(entry.outputLanguage, statement: statement, column: 8)
        sqlite3_bind_text(statement, 9, "sent", -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    private func prune(limit: Int) throws {
        let sql = """
        DELETE FROM history_entries
        WHERE id IN (
            SELECT id
            FROM history_entries
            ORDER BY created_at DESC
            LIMIT -1 OFFSET ?
        );
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func bindOptionalText(_ value: String?, statement: OpaquePointer?, column: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, column)
            return
        }
        sqlite3_bind_text(statement, column, value, -1, transientDestructor)
    }

    private func string(from statement: OpaquePointer?, column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    private func databaseError(database: OpaquePointer? = nil) -> NSError {
        let db = database ?? self.database
        let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "Unknown SQLite error"
        return NSError(domain: "LocalHistoryStore", code: Int(sqlite3_errcode(db)), userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

    private var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
    }
}
