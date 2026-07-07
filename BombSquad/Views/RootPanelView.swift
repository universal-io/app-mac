import SwiftUI

/// Thin router over the coordinator's mode (redesign plan §6): each mode has
/// its own content view; auth gates everything. No mode logic lives here —
/// the switch is the whole job.
struct RootPanelView: View {
    @ObservedObject var coordinator: SessionCoordinator
    // Shared app-wide auth state, not a per-panel instance — see AuthViewModel.shared.
    @ObservedObject var authViewModel: AuthViewModel
    let config: BombSquadConfig.Snapshot
    @State private var didAutoInterpretAfterLogin = false

    @MainActor
    init(
        coordinator: SessionCoordinator,
        authViewModel: AuthViewModel = .shared,
        config: BombSquadConfig.Snapshot = BombSquadConfig.snapshot()
    ) {
        self.coordinator = coordinator
        self.authViewModel = authViewModel
        self.config = config
    }

    var body: some View {
        Group {
            if authViewModel.hasSession {
                // compose and capturing share one branch (and one view
                // identity): the capture overlay merely suspends compose, and
                // an identity change here would reset the editor's first
                // responder.
                if let composeSession = coordinator.mode.activeComposeSession {
                    ComposeContentView(session: composeSession)
                } else {
                    switch coordinator.mode {
                    case .transform(let session):
                        TransformContentView(session: session)
                    case .legacyVision(let viewModel):
                        LegacyVisionRootView(viewModel: viewModel)
                    default:
                        Color.clear
                    }
                }
            } else {
                LoginRequiredView(viewModel: authViewModel, config: config)
            }
        }
        .panelChrome()
        .onChange(of: authViewModel.hasSession) { _, isLoggedIn in
            // One-stop receiving across a mid-session login: the transform
            // that could not run while signed out fires once on login.
            guard isLoggedIn,
                  case .transform(let session) = coordinator.mode,
                  session.interpretation == nil, !session.isLoading,
                  !didAutoInterpretAfterLogin else { return }
            didAutoInterpretAfterLogin = true
            session.startInterpretation()
        }
    }
}

/// R1-a bridge: vision / navigator / copilot still run on the legacy view
/// model; this wrapper observes it so the copilot strip swap re-renders.
private struct LegacyVisionRootView: View {
    @ObservedObject var viewModel: ReviewViewModel

    var body: some View {
        if viewModel.navigatorActiveTask != nil {
            // Guided navigation: the whole panel becomes the corner strip;
            // the screen being navigated is the real UI.
            CopilotStripView(viewModel: viewModel)
        } else {
            VisionPanelView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

/// Compose layout: a single Spotlight-style column — input on top, result
/// below. Three states only: empty → draft → result (design principle 3.5).
struct ComposeContentView: View {
    @ObservedObject var session: ComposeSession

    /// True once the bottom area holds live content (spinner or result), at
    /// which point the input yields most of the vertical space to it.
    private var isResultActive: Bool {
        session.result != nil || session.isLoading
    }

    var body: some View {
        VStack(spacing: 0) {
            StagingEditorView(session: session, focusedField: $session.focusedField)
                .frame(maxHeight: isResultActive ? 190 : .infinity)
            ReviewPanelView(session: session, focusedField: $session.focusedField)
                .frame(maxHeight: .infinity)
        }
        .animation(.spring(duration: 0.35), value: isResultActive)
        .frame(minWidth: 620, minHeight: 640)
        .onAppear {
            // Defer so the panel is key before focusing the original editor.
            DispatchQueue.main.async {
                session.focusedField = .draft
            }
        }
    }
}
