import AppKit
import SwiftUI

/// Input events the coordinator understands. AppDelegate (or, later, the
/// monitors directly) translates raw gestures into these; nothing else in
/// the core knows about NSEvent.
enum AppEvent: CustomStringConvertible {
    /// Right Shift single tap: toggle editor focus (mode-dependent).
    case singleTap
    /// Right Shift double tap: summon / review / vision / close.
    case doubleTap
    /// Right Shift held: hold-to-talk dictation.
    case longPressBegan
    case longPressEnded
    /// ⌘J: plain panel toggle.
    case hotKeyToggle
    /// Esc or an in-window close request.
    case closeRequested
    /// The app lost active status (another app's window took focus).
    case appResignedActive

    var description: String {
        switch self {
        case .singleTap: return "singleTap"
        case .doubleTap: return "doubleTap"
        case .longPressBegan: return "longPressBegan"
        case .longPressEnded: return "longPressEnded"
        case .hotKeyToggle: return "hotKeyToggle"
        case .closeRequested: return "closeRequested"
        case .appResignedActive: return "appResignedActive"
        }
    }
}

/// The rebuilt center: translates events into `AppMode` transitions and
/// drives the `PanelController`. This is the ONLY place that decides what a
/// gesture means in a given mode.
///
/// Phase 1 scope (docs/foundation-rebuild-plan.md): the machinery itself —
/// summon/close with a placeholder content view proving the state machine
/// and panel geometry on device. Phase 3 ports the real mode sessions in
/// one at a time.
@MainActor
final class SessionCoordinator {
    /// Developer flag: `defaults write <bundle-id> core.foundation.enabled -bool YES`.
    /// Default OFF — the legacy path stays the shipping behavior until
    /// Phase 4 parity (docs/foundation-rebuild-plan.md §Phase 4).
    static let enabledDefaultsKey = "core.foundation.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    static func makeIfEnabled() -> SessionCoordinator? {
        isEnabled ? SessionCoordinator() : nil
    }

    let stateMachine = AppStateMachine()
    private let panelController = PanelController()

    init() {
        panelController.onCloseRequested = { [weak self] in
            self?.handle(.closeRequested)
        }
        stateMachine.onTransition = { [weak self] _, next, _ in
            self?.applyPanel(for: next)
        }
        CoreTrace.event("coordinator.started", mode: stateMachine.mode)
    }

    /// Single entry point for all input events.
    func handle(_ event: AppEvent) {
        let mode = stateMachine.mode
        CoreTrace.event("coordinator.event", mode: mode, details: ["event": event.description])
        switch event {
        case .doubleTap:
            handleDoubleTap(in: mode)
        case .hotKeyToggle:
            if mode == .idle {
                summon()
            } else {
                close(reason: "hotKeyToggle")
            }
        case .closeRequested:
            close(reason: "closeRequested")
        case .appResignedActive:
            guard let spec = PanelSpec.forMode(mode), spec.closesOnResignActive else { return }
            close(reason: "resignActive")
        case .singleTap, .longPressBegan, .longPressEnded:
            // Phase 3: editor focus toggle and dictation arrive with the
            // ported mode sessions. Traced but inert in the Phase 1 shell.
            break
        }
    }

    // MARK: - Event handling per mode

    private func handleDoubleTap(in mode: AppMode) {
        switch mode {
        case .idle:
            summon()
        case .vision, .navigator, .copilot:
            close(reason: "doubleTapOnVision")
        case .compose, .transform:
            // Phase 3: review-on-double-tap / capture entry. Until the mode
            // sessions are ported, double tap simply closes the shell.
            close(reason: "doubleTapPhase1Shell")
        case .capturing(let returnTo):
            // Abandon the capture session entirely: back to standby.
            _ = returnTo
            close(reason: "doubleTapDuringCapture")
        }
    }

    /// Summon. Phase 1: always the compose shell (selection-grab branching
    /// into transform is ported in Phase 3-b together with the session).
    private func summon() {
        guard stateMachine.transition(to: .compose, reason: "summon") else { return }
    }

    private func close(reason: String) {
        guard stateMachine.mode != .idle else { return }
        stateMachine.transition(to: .idle, reason: reason)
    }

    // MARK: - Panel

    private func applyPanel(for mode: AppMode) {
        if mode.hasPanel {
            if panelController.isVisible {
                panelController.applyMode(mode)
            } else {
                panelController.present(
                    CorePanelShellView(stateMachine: stateMachine),
                    for: mode
                )
            }
        } else if case .capturing = mode {
            panelController.hide()
        } else {
            panelController.close()
        }
    }
}

/// Phase 1 placeholder content: proves on device that gestures drive the
/// state machine and the window geometry follows the mode. Replaced mode by
/// mode in Phase 3.
struct CorePanelShellView: View {
    @ObservedObject var stateMachine: AppStateMachine

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("I//O Core shell (Phase 1)")
                .font(.headline)
            Text("mode: \(stateMachine.mode.description)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Right-Shift double-tap or Esc closes. Legacy path is untouched; disable with:\ndefaults delete \(Bundle.main.bundleIdentifier ?? "<bundle-id>") \(SessionCoordinator.enabledDefaultsKey)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
