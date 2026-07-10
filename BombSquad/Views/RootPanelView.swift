import SwiftUI

struct RootPanelView: View {
    // Shared app-wide auth state, not a per-panel instance — see AuthViewModel.shared.
    @ObservedObject var authViewModel: AuthViewModel
    @ObservedObject private var reviewViewModel: ReviewViewModel
    let session: PanelSession
    let config: BombSquadConfig.Snapshot
    @State private var didAutoReviewAfterLogin = false

    @MainActor
    init(
        session: PanelSession,
        config: BombSquadConfig.Snapshot = BombSquadConfig.snapshot()
    ) {
        self.session = session
        self._reviewViewModel = ObservedObject(wrappedValue: session.viewModel)
        self.authViewModel = .shared
        self.config = config
    }

    @MainActor
    init(
        session: PanelSession,
        authViewModel: AuthViewModel,
        config: BombSquadConfig.Snapshot = BombSquadConfig.snapshot()
    ) {
        self.session = session
        self._reviewViewModel = ObservedObject(wrappedValue: session.viewModel)
        self.authViewModel = authViewModel
        self.config = config
    }

    var body: some View {
        Group {
            if authViewModel.hasSession {
                switch session.presentation {
                case .copilot(let viewModel):
                    // Guided navigation: the whole panel becomes the corner
                    // strip; the screen being navigated is the real UI.
                    CopilotStripView(viewModel: viewModel)
                case .vision(let viewModel):
                    VisionContentView(viewModel: viewModel)
                case .compose(let session):
                    ComposeContentView(session: session)
                case .transform(let session):
                    TransformContentView(session: session)
                }
            } else {
                LoginRequiredView(viewModel: authViewModel, config: config)
            }
        }
        .panelChrome()
        .onChange(of: authViewModel.hasSession) { _, isLoggedIn in
            guard isLoggedIn else { return }
            guard session.shouldAutoReviewAfterLogin else { return }
            guard !didAutoReviewAfterLogin else { return }

            didAutoReviewAfterLogin = true
            Task { await reviewViewModel.runReview() }
        }
    }
}
