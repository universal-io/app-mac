import Foundation

/// DEBUG only: one directory per companion session in
/// ~/Library/Application Support/UniversalIO/CompanionSessions, holding what the unified log never
/// does — the words. `conversation.jsonl` has the user's and the companion's
/// transcripts, the turns and notes the app sent, the looks the voice asked
/// for and what it was told, in order and timed from the session's start.
/// Each read of the screen (`look-N-request.json` / `-response.json`) keeps the
/// body sent to /ai/vision, screenshot included, and what came back, so the
/// same moment can be read again by another model or at another effort.
///
/// Not /tmp: a restart emptied it on 2026-10-10 and took the After Effects
/// session the next experiment was to be run on. The newest `kept` sessions
/// stay; older ones are removed when a session starts.
///
/// Release builds compile no recording: `start()` returns nil and every
/// method is empty.
final class CompanionTrace: @unchecked Sendable {
    #if DEBUG
    private let directory: URL
    private let started = Date()
    private let queue = DispatchQueue(label: "companion.trace")
    private var handle: FileHandle?
    private var looks = 0

    private init(directory: URL, handle: FileHandle) {
        self.directory = directory
        self.handle = handle
    }
    #endif

    static func start() -> CompanionTrace? {
        #if DEBUG
        // Unit tests drive sessions too; their records would look like real ones.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let file: URL
        let directory: URL
        do {
            let root = try AppSupport.directory().appendingPathComponent("CompanionSessions", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            prune(root)
            directory = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
            file = directory.appendingPathComponent("conversation.jsonl")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            NSLog("Companion trace: %@", directory.path)
            return CompanionTrace(directory: directory, handle: handle)
        } catch {
            NSLog("Companion trace failed: %@", String(describing: error))
            return nil
        }
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static let kept = 30

    /// Session folders are named by their start time, so the oldest sort first.
    private static func prune(_ root: URL) {
        let sessions = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        for name in sessions.dropLast(kept - 1) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }
    #endif

    /// One line of the conversation: `kind` and its fields, with the seconds
    /// since the session started.
    func record(_ kind: String, _ fields: [String: Any] = [:]) {
        #if DEBUG
        let at = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
        var line = fields
        line["t"] = at
        line["kind"] = kind
        queue.async { [weak self] in
            guard let self, let handle = self.handle,
                  let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            else { return }
            handle.write(data + Data("\n".utf8))
        }
        #endif
    }

    /// The next look's number; its request and response are written under it.
    func nextLook() -> Int {
        #if DEBUG
        return queue.sync {
            looks += 1
            return looks
        }
        #else
        return 0
        #endif
    }

    func saveLook(_ number: Int, request: Data, response: Data) {
        #if DEBUG
        queue.async { [directory] in
            try? request.write(to: directory.appendingPathComponent("look-\(number)-request.json"))
            try? response.write(to: directory.appendingPathComponent("look-\(number)-response.json"))
        }
        #endif
    }

    func close() {
        #if DEBUG
        queue.async { [weak self] in
            try? self?.handle?.close()
            self?.handle = nil
        }
        #endif
    }
}
