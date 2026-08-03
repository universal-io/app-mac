import Foundation

/// The single source of truth for "what the app is doing right now".
///
/// Introduced by the foundation rebuild. The app owns mode explicitly here;
/// panels, gestures, and session lifetimes all derive from this value.
enum AppMode: Equatable, CustomStringConvertible {
    /// No panel. Menu-bar resident, waiting for a summon gesture.
    case idle
    /// Sending side: draft → review → deploy.
    case compose
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
        // Explicit compose summons (menu bar / hold-to-talk).
        case (.idle, .compose):
            return true
        // Right-Shift summon resolves AX focus while capturing the screen.
        case (.idle, .capturing):
            return true
        // Capture resolves to Compose when the same AX snapshot found an
        // editable field, or to Vision otherwise.
        case (.compose, .capturing), (.capturing, .compose), (.capturing, .vision):
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

/// Why a transition was attempted.
///
/// A closed vocabulary rather than a free string, because every one of these
/// reaches the device log and the diagnostics trail the user can copy out.
/// A `String` here would make it possible to log something read off the screen.
enum TransitionReason: String {
    case captureCancelled
    case captureCompleted
    case captureFailed
    case captureTransitionFailed
    case closeRequested
    case composeDeploy
    case composePreCaptureVision
    case copilotStarted
    case doubleTapDuringCapture
    case doubleTapOnVision
    case emptyComposeCapture
    case idleAXFocusSummon
    case menuPanelToggle
    case resignActive
    case summon
    case visionGuideReady
    case visionRequestedClose
}

/// Owns the current `AppMode` and enforces the transition table.
/// All mutations go through `transition(to:reason:)` — there is deliberately
/// no other setter, so a grep for `transition(` shows every state change.
@MainActor
final class AppStateMachine: ObservableObject {
    @Published private(set) var mode: AppMode = .idle

    /// Called after every successful transition (old, new, reason).
    var onTransition: ((AppMode, AppMode, TransitionReason) -> Void)?

    /// Attempts a transition. Illegal transitions are refused and logged;
    /// in DEBUG they also assert so they surface during development.
    ///
    /// The result is deliberately NOT `@discardableResult`. A caller that
    /// ignores a refusal keeps running as if the mode had changed — which is
    /// how `close()` could tear a session down while the panel stayed up
    /// (docs/reliability-hardening-plan.md D6). Ignoring it must be written out.
    func transition(to next: AppMode, reason: TransitionReason) -> Bool {
        let current = mode
        guard current.canTransition(to: next) else {
            Diagnostics.record("state.transition.refused", mode: current, details: [
                ("to", .code(next)),
                ("reason", .code(reason))
            ])
            // The assert exists to surface a programming error while developing.
            // A test that deliberately drives the refusal path is not that, and
            // refusal handling is precisely what needs covering: it is the case
            // that used to leave a panel with no session behind it.
            if !AppRuntime.isRunningUnitTests {
                assertionFailure("Illegal AppMode transition \(current) → \(next) (\(reason))")
            }
            return false
        }
        mode = next
        Diagnostics.record("state.transition", mode: next, details: [
            ("from", .code(current)),
            ("reason", .code(reason))
        ])
        onTransition?(current, next, reason)
        return true
    }
}
