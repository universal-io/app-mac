import Foundation

/// The ONE source of truth for "what is the app doing right now"
/// (docs/foundation-redesign-plan.md §4-b).
///
/// Modes are mutually exclusive by construction: at most one session object
/// exists at a time. Continuity across transitions (e.g. the compose draft)
/// is handled by persistence (`ComposeDraftStore`), never by keeping inactive
/// sessions alive — exclusivity by enum, continuity by persistence.
enum AppMode {
    /// Panel closed, standby. The gesture monitor is the only thing running.
    case idle
    /// Outgoing review: staging draft → review → deploy.
    case compose(ComposeSession)
    /// Receiving side: a selected message → readable interpretation.
    case transform(TransformSession)
    /// The screenshot selection overlay is up and the panel is hidden. Holds
    /// the compose session to resume on cancel — suspended, not running.
    case capturing(resume: ComposeSession)
    /// Screen Q&A over a screenshot (plus the one-shot fallback).
    case navigator(NavigatorSession)
    /// Guided navigation: the corner strip + the user's own clicks. Wraps the
    /// navigator whose conversation it continues (explicit handoff §4-b).
    case copilot(CopilotSession)
}

extension AppMode {
    /// The compose session, whether active or suspended behind the capture
    /// overlay. Used by the root view so compose ↔ capturing keeps one stable
    /// view identity (no editor first-responder reset).
    var activeComposeSession: ComposeSession? {
        switch self {
        case .compose(let session), .capturing(resume: let session):
            return session
        default:
            return nil
        }
    }
}
