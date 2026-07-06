import Foundation

/// The app's Application Support directory, shared by every local store
/// (history, memory). The folder was renamed from the old "BombSquad" name to
/// "UniversalIO"; on first access any existing legacy folder is moved intact so
/// a user's history and memory carry over silently. Because both stores route
/// through here, the migration runs once — whichever store is opened first.
enum AppSupport {
    private static let directoryName = "UniversalIO"
    private static let legacyDirectoryName = "BombSquad"

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
}
