import Foundation
import SQLite3

/// A finished navigator conversation, kept for re-reading (view + copy only —
/// the screen has moved on, so sessions are never resumed).
struct NavigatorSessionRecord: Identifiable {
    struct Turn: Codable {
        let role: String
        let text: String
    }

    let id: UUID
    let createdAt: Date
    /// The first user question, or the opening recognition line.
    let title: String
    let turns: [Turn]
}

/// Local, text-only store of recent navigator sessions (same pattern as
/// LocalHistoryStore: SQLite in Application Support, on by default, capped,
/// honors the history setting). Screenshots are deliberately NOT persisted —
/// the privacy line is that screen captures never outlive the session.
actor NavigatorSessionStore {
    static let shared = NavigatorSessionStore()
    static let sessionLimit = 10

    private var database: OpaquePointer?
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    deinit {
        sqlite3_close(database)
    }

    func save(turns: [NavigatorSessionRecord.Turn]) async {
        guard AppSettings.isHistoryEnabled() else { return }
        guard turns.contains(where: { $0.role == "assistant" }) else { return }
        do {
            try openIfNeeded()
            try insert(turns: turns)
            try prune(limit: Self.sessionLimit)
        } catch {
            NSLog("[SessionStore] save failed: %@", error.localizedDescription)
        }
    }

    func recent(limit: Int = NavigatorSessionStore.sessionLimit) async -> [NavigatorSessionRecord] {
        do {
            try openIfNeeded()
            return try fetch(limit: limit)
        } catch {
            NSLog("[SessionStore] fetch failed: %@", error.localizedDescription)
            return []
        }
    }

    // MARK: - SQLite

    private func openIfNeeded() throws {
        guard database == nil else { return }
        let directoryURL = try AppSupport.directory()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let databaseURL = directoryURL.appendingPathComponent("navigator-sessions.sqlite")
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw storeError(db)
        }
        database = db
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL,
                title TEXT NOT NULL,
                turns_json TEXT NOT NULL
            );
            """
        )
    }

    private func insert(turns: [NavigatorSessionRecord.Turn]) throws {
        let title = turns.first(where: { $0.role == "user" && !$0.text.hasPrefix("（") })?.text
            ?? turns.first?.text ?? "セッション"
        let json = String(
            data: (try? JSONEncoder().encode(turns)) ?? Data("[]".utf8),
            encoding: .utf8
        ) ?? "[]"

        var statement: OpaquePointer?
        let sql = "INSERT INTO sessions (id, created_at, title, turns_json) VALUES (?, ?, ?, ?);"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError(database)
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, transient)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, String(title.prefix(80)), -1, transient)
        sqlite3_bind_text(statement, 4, json, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw storeError(database)
        }
    }

    private func fetch(limit: Int) throws -> [NavigatorSessionRecord] {
        let sql = "SELECT id, created_at, title, turns_json FROM sessions ORDER BY created_at DESC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError(database)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var records: [NavigatorSessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(statement, 0),
                let id = UUID(uuidString: String(cString: idText)),
                let titleText = sqlite3_column_text(statement, 2),
                let jsonText = sqlite3_column_text(statement, 3),
                let turns = try? JSONDecoder().decode(
                    [NavigatorSessionRecord.Turn].self,
                    from: Data(String(cString: jsonText).utf8)
                )
            else { continue }
            records.append(NavigatorSessionRecord(
                id: id,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                title: String(cString: titleText),
                turns: turns
            ))
        }
        return records
    }

    private func prune(limit: Int) throws {
        let sql = """
        DELETE FROM sessions WHERE id IN (
            SELECT id FROM sessions ORDER BY created_at DESC LIMIT -1 OFFSET ?
        );
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storeError(database)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw storeError(database)
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw storeError(database)
        }
    }

    private func storeError(_ db: OpaquePointer?) -> NSError {
        let message = sqlite3_errmsg(db ?? database).map { String(cString: $0) } ?? "Unknown SQLite error"
        return NSError(domain: "NavigatorSessionStore", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
