import Foundation
import os

/// Types whose textual form is a closed vocabulary the app itself writes.
///
/// Conformance is the review point. A type that can carry text read off the
/// user's screen — a window title, a host name, a draft, a model answer —
/// must never conform, because everything reachable through this protocol is
/// written to the device log and can be copied out by the user.
protocol DiagnosticCode {
    var diagnosticCode: String { get }
}

/// What a diagnostic entry may carry.
///
/// There is deliberately no case taking a free `String`. Recording a message
/// body or a window title is therefore not something a caller can do by
/// accident: it requires adding a case here, which is a visible act in review.
/// README「データ保存」の境界を、この型が構造として持つ。
enum DiagnosticValue {
    case ms(Int)
    case count(Int)
    case flag(Bool)
    /// Compile-time literal. Cannot carry runtime data by construction.
    case literal(StaticString)
    case code(any DiagnosticCode)

    var text: String {
        switch self {
        case .ms(let value): return "\(value)ms"
        case .count(let value): return "\(value)"
        case .flag(let value): return value ? "true" : "false"
        case .literal(let value): return "\(value)"
        case .code(let value): return value.diagnosticCode
        }
    }
}

/// One recorded moment: what happened, in which mode, with which numbers.
struct DiagnosticEntry {
    let at: Date
    let event: String
    let mode: String?
    let details: [(key: String, value: String)]

    var line: String {
        var parts = [Diagnostics.timestamp(at), event]
        if let mode { parts.append("mode=\(mode)") }
        parts.append(contentsOf: details.map { "\($0.key)=\($0.value)" })
        return parts.joined(separator: " ")
    }
}

/// Operational trace that survives into release builds.
///
/// The 2026-08-03 silent stall was diagnosable only because a DEBUG build
/// happened to be running: `CoreTrace`/`VisionTrace` compiled to nothing in
/// Release, so a shipped app in the same state would have left no evidence at
/// all. Two things are needed and neither existed:
///
/// 1. The record must exist in Release — hence `os_log` rather than `#if DEBUG`.
/// 2. The user must be able to hand it over. A customer's unified log is not
///    reachable without sysdiagnose, so the same entries are kept in memory and
///    copied from the management window.
///
/// What is recorded is only what separates "never started" from "started and
/// never answered": event name, mode, elapsed milliseconds, counts, and codes
/// from closed vocabularies. See `DiagnosticValue`.
enum Diagnostics {
    /// Deep enough to cover a long session's worth of summons, small enough to
    /// stay irrelevant against a 44MB resident size.
    static let capacity = 200

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.universal-io.mac",
        category: "reliability"
    )

    private static let lock = NSLock()
    private nonisolated(unsafe) static var entries: [DiagnosticEntry] = []
    private nonisolated(unsafe) static var startedAt = Date()

    /// Records one event to the device log and the in-memory trail.
    static func record(
        _ event: StaticString,
        mode: AppMode? = nil,
        details: [(StaticString, DiagnosticValue)] = []
    ) {
        let entry = DiagnosticEntry(
            at: Date(),
            event: "\(event)",
            mode: mode?.description,
            details: details.map { (key: "\($0.0)", value: $0.1.text) }
        )
        // `.public` is correct here and load-bearing: the vocabulary is closed
        // by `DiagnosticValue`, and redacting it would hide exactly the fields
        // an operator needs while protecting nothing.
        logger.notice("\(entry.line, privacy: .public)")
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    static var recordedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    static func recent(_ limit: Int) -> [DiagnosticEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(limit))
    }

    /// The text the user copies. Carries how long this process has been alive,
    /// because the failure this whole project exists for only appears after a
    /// long uptime — a report without it cannot be placed.
    static func exportText(now: Date = Date()) -> String {
        lock.lock()
        let snapshot = entries
        let launched = startedAt
        lock.unlock()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let header = [
            "Universal I/O \(version) (\(build))",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "uptime=\(uptimeText(since: launched, now: now))",
            "entries=\(snapshot.count)",
        ].joined(separator: " ")

        return ([header] + snapshot.map(\.line)).joined(separator: "\n")
    }

    /// Test seam. Production never resets: the trail is the process's history.
    static func resetForTesting(launchedAt: Date = Date()) {
        lock.lock()
        entries = []
        startedAt = launchedAt
        lock.unlock()
    }

    static func uptimeText(since launched: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(launched)))
        return "\(total / 3600)h\((total % 3600) / 60)m"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // Same shape as the unified log's compact style, so a copied trail and
        // `log show` output can be read side by side.
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

extension AppMode: DiagnosticCode {
    var diagnosticCode: String { description }
}

extension AppEvent: DiagnosticCode {
    var diagnosticCode: String { description }
}

extension TransitionReason: DiagnosticCode {
    var diagnosticCode: String { rawValue }
}

/// An error reduced to what is safe to record: its class and, for HTTP, its
/// status. Never its message. `ProviderError.http` carries a response body and
/// `.gateway` carries text the server wrote — exactly what must not reach a log
/// the user can copy out.
struct DiagnosticErrorClass: DiagnosticCode {
    let diagnosticCode: String

    init(_ error: Error) {
        if error is CancellationError {
            diagnosticCode = "cancelled"
        } else if let provider = error as? ProviderError {
            switch provider {
            case .missingAPIKey: diagnosticCode = "provider.missingAPIKey"
            case .http(let status, _): diagnosticCode = "provider.http.\(status)"
            case .noStructuredOutput: diagnosticCode = "provider.noStructuredOutput"
            case .decoding: diagnosticCode = "provider.decoding"
            case .emptyDraft: diagnosticCode = "provider.emptyDraft"
            case .gateway: diagnosticCode = "provider.gateway"
            }
        } else {
            let nsError = error as NSError
            diagnosticCode = nsError.domain == NSURLErrorDomain
                ? "url.\(nsError.code)"
                : "\(type(of: error))"
        }
    }
}

/// Which shape of answer came back. A fixed four-case vocabulary defined by the
/// gateway contract, never text read off the screen.
extension VisionResult.Mode: DiagnosticCode {
    var diagnosticCode: String { rawValue }
}

extension AXFocusSnapshot.CaptureStatus: DiagnosticCode {
    var diagnosticCode: String { String(describing: self) }
}

extension AXFocusLaunchDecision.Destination: DiagnosticCode {
    var diagnosticCode: String { String(describing: self) }
}
