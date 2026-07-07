import Foundation

/// Lifecycle contract for mode sessions (redesign plan §4-b). `willEnd()` is
/// called exactly once by the coordinator right before the session is
/// discarded; it must cancel in-flight tasks, global monitors, and overlays.
/// The call site lives in the coordinator's transition handling only — never
/// scattered across views or the app delegate.
@MainActor
protocol SessionLifecycle: AnyObject {
    func willEnd()
}

/// Where hold-to-talk dictation lands. Resolved from the current mode by the
/// coordinator so the recording flow is written once for every session kind.
@MainActor
protocol DictationTarget: AnyObject {
    var isRecording: Bool { get set }
    var isTranscribing: Bool { get set }
    var errorMessage: String? { get set }
    func appendTranscription(_ text: String)
}

/// Memory cards (L2/L3) selected for one model call: the persona card plus
/// the relationship card whose subject appears in the situational context.
/// Shared by every session kind.
enum SessionMemory {
    static func injection(for context: SituationalContext?) async -> MemoryInjection? {
        guard AppSettings.isMemoryEnabled() else { return nil }
        let persona = try? await MemoryStore.shared.personaCard()

        var relationship: MemoryCard?
        if let context {
            let haystack = [context.windowTitle, context.conversationExcerpt]
                .compactMap { $0 }
                .joined(separator: "\n")
            relationship = try? await MemoryStore.shared.matchRelationship(inText: haystack)
        }

        let injection = MemoryInjection(
            personaMD: persona?.contentMD,
            relationshipSubject: relationship?.subject,
            relationshipMD: relationship?.contentMD
        )
        return injection.isEmpty ? nil : injection
    }
}
