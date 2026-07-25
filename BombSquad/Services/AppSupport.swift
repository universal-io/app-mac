import Foundation

enum AppRuntime {
    static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }
}

/// The app's Application Support directory, shared by every local store.
/// The folder was renamed from the old "BombSquad" name to "UniversalIO"; on
/// first access any existing legacy folder is moved intact so a user's local
/// data carries over silently. Because every store routes through here, the
/// migration runs once — whichever store is opened first.
enum AppSupport {
    private static let directoryName = "UniversalIO"
    private static let legacyDirectoryName = "BombSquad"
    private static let pendingDeletionPrefix = "localData.pendingAccountDeletion."

    static func directory() throws -> URL {
        guard let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        let current = root.appendingPathComponent(directoryName, isDirectory: true)
        migrateLegacyIfNeeded(root: root, to: current)
        return current
    }

    /// Account-owned local data lives below a UUID-named directory. Keeping
    /// the account id in the path makes it impossible for a later login to
    /// open another user's history database by accident.
    static func accountDirectory(
        for userID: UUID,
        migrateLegacyDatabases: Bool = false
    ) throws -> URL {
        let root = try directory()
        let accounts = root.appendingPathComponent("Accounts", isDirectory: true)
        let account = accounts.appendingPathComponent(userID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)

        if migrateLegacyDatabases {
            migrateLegacyDatabase(named: "history.sqlite", from: root, to: account)
        }
        return account
    }

    static func removeAccountDirectory(for userID: UUID) throws {
        let account = try accountDirectory(for: userID)
        guard FileManager.default.fileExists(atPath: account.path) else { return }
        try FileManager.default.removeItem(at: account)
    }

    static func markAccountForDeletion(_ userID: UUID) {
        UserDefaults.standard.set(true, forKey: pendingDeletionPrefix + userID.uuidString.lowercased())
    }

    static func clearPendingAccountDeletion(_ userID: UUID) {
        UserDefaults.standard.removeObject(forKey: pendingDeletionPrefix + userID.uuidString.lowercased())
    }

    /// A database handle or transient filesystem error must not strand local
    /// data after the server identity is already gone. Retry pending account
    /// directory removals before any store opens on the next launch.
    static func cleanupPendingAccountDeletions() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(pendingDeletionPrefix) {
            let rawID = String(key.dropFirst(pendingDeletionPrefix.count))
            guard let userID = UUID(uuidString: rawID) else {
                defaults.removeObject(forKey: key)
                continue
            }
            do {
                try removeAccountDirectory(for: userID)
                clearPendingAccountDeletion(userID)
            } catch {
                NSLog("Universal I/O pending local account cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    /// v3 removed the style/relationship memory feature. Its database held
    /// personal notes, so leaving the file behind would keep data the user can
    /// no longer see or delete from the app. Erase it once, everywhere it could
    /// have been written (pre-account root and every account directory).
    static func removeRetiredMemoryDatabases() {
        let fileManager = FileManager.default
        guard let root = try? directory() else { return }
        var directories = [root]
        let accounts = root.appendingPathComponent("Accounts", isDirectory: true)
        if let children = try? fileManager.contentsOfDirectory(
            at: accounts,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            directories.append(contentsOf: children)
        }
        for directory in directories {
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: directory.appendingPathComponent("memory.sqlite").path + suffix)
                guard fileManager.fileExists(atPath: file.path) else { continue }
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// Moves the legacy folder to the current name only when the legacy folder
    /// exists and the new one does not — so a fresh install and an
    /// already-migrated install both no-op.
    private static func migrateLegacyIfNeeded(root: URL, to current: URL) {
        let fileManager = FileManager.default
        let legacy = root.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: current.path)
        else { return }
        try? fileManager.moveItem(at: legacy, to: current)
    }

    private static func migrateLegacyDatabase(named name: String, from root: URL, to account: URL) {
        let fileManager = FileManager.default
        let source = root.appendingPathComponent(name)
        let destination = account.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path)
        else { return }

        do {
            try fileManager.moveItem(at: source, to: destination)
            for suffix in ["-wal", "-shm"] {
                let sidecarSource = URL(fileURLWithPath: source.path + suffix)
                let sidecarDestination = URL(fileURLWithPath: destination.path + suffix)
                if fileManager.fileExists(atPath: sidecarSource.path) {
                    try? fileManager.moveItem(at: sidecarSource, to: sidecarDestination)
                }
            }
        } catch {
            NSLog("Universal I/O local data migration failed for \(name): \(error.localizedDescription)")
        }
    }
}
