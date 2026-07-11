import Foundation

/// The single source of truth for "what the app is doing right now".
///
/// Foundation rebuild Phase 1 (docs/foundation-rebuild-plan.md §Phase 1).
/// The legacy path *infers* this from scattered view-model flags
/// (`sessionKind`, `navigatorSessionActive`, `navigatorActiveTask`, ...);
/// the rebuilt core *owns* it here and everything else derives from it.
/// Core files must not import the legacy center (ReviewViewModel, the old
/// AppDelegate flow) — leaf services only.
enum AppMode: Equatable, CustomStringConvertible {
    /// No panel. Menu-bar resident, waiting for a summon gesture.
    case idle
    /// Sending side: draft → review → deploy.
    case compose
    /// Receiving side: selected text → readable version. Exit is copy-only.
    case transform
    /// See → understand → respond: screenshot interpretation with actions.
    case vision
    /// Multi-turn screen navigation chat on top of a vision session.
    case navigator
    /// Guided copilot: corner strip, target-app clicks are the interaction.
    case copilot
    /// The selection overlay / screenshot capture is up. Remembers where to
    /// return so a cancelled capture restores the previous mode.
    indirect case capturing(returnTo: AppMode)

    var description: String {
        switch self {
        case .idle: return "idle"
        case .compose: return "compose"
        case .transform: return "transform"
        case .vision: return "vision"
        case .navigator: return "navigator"
        case .copilot: return "copilot"
        case .capturing(let returnTo): return "capturing(returnTo=\(returnTo))"
        }
    }

    /// Whether a panel window exists in this mode.
    var hasPanel: Bool {
        switch self {
        case .idle: return false
        case .capturing: return false // panel is ordered out during capture
        default: return true
        }
    }

    /// Legal transitions. Anything not listed here is a programming error —
    /// the state machine refuses it and logs loudly instead of corrupting state.
    func canTransition(to next: AppMode) -> Bool {
        if self == next { return false }
        switch (self, next) {
        // Summon: selection present → transform, otherwise compose.
        case (.idle, .compose), (.idle, .transform):
            return true
        // Empty draft double-tap enters capture; capture yields vision.
        case (.compose, .capturing), (.capturing, .vision):
            return true
        // Cancelled capture returns to where it came from (or all the way out).
        case (.capturing(let returnTo), let target) where target == returnTo:
            return true
        // Vision escalates to navigator (first question) and copilot (task plan).
        case (.vision, .navigator), (.navigator, .copilot):
            return true
        // Copilot ends back on the navigator answer view.
        case (.copilot, .navigator):
            return true
        // Vision action drafts carry into the compose editor.
        case (.vision, .compose), (.navigator, .compose):
            return true
        // Everything can close to idle.
        case (_, .idle):
            return true
        default:
            return false
        }
    }
}

/// Owns the current `AppMode` and enforces the transition table.
/// All mutations go through `transition(to:reason:)` — there is deliberately
/// no other setter, so a grep for `transition(` shows every state change.
@MainActor
final class AppStateMachine: ObservableObject {
    @Published private(set) var mode: AppMode = .idle

    /// Called after every successful transition (old, new, reason).
    var onTransition: ((AppMode, AppMode, String) -> Void)?

    /// Attempts a transition. Illegal transitions are refused and logged;
    /// in DEBUG they also assert so they surface during development.
    @discardableResult
    func transition(to next: AppMode, reason: String) -> Bool {
        let current = mode
        guard current.canTransition(to: next) else {
            CoreTrace.event("state.transition.refused", mode: current, details: [
                "to": next.description,
                "reason": reason
            ])
            assertionFailure("Illegal AppMode transition \(current) → \(next) (\(reason))")
            return false
        }
        mode = next
        CoreTrace.event("state.transition", mode: next, details: [
            "from": current.description,
            "reason": reason
        ])
        onTransition?(current, next, reason)
        return true
    }
}

/// Debug trace for the rebuilt core. Mirrors the legacy `SessionTrace`
/// format so Console.app filtering works the same way, but reports the
/// *owned* mode instead of an inferred one.
enum CoreTrace {
    static func event(
        _ name: String,
        mode: AppMode,
        details: [String: CustomStringConvertible?] = [:]
    ) {
        #if DEBUG
        let detailText = details
            .compactMap { key, value -> String? in
                guard let value else { return nil }
                return "\(key)=\(value)"
            }
            .sorted()
            .joined(separator: " ")
        if detailText.isEmpty {
            NSLog("[CoreTrace] %@ mode=%@", name, mode.description)
        } else {
            NSLog("[CoreTrace] %@ mode=%@ %@", name, mode.description, detailText)
        }
        #endif
    }
}
