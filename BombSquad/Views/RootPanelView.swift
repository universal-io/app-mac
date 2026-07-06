import SwiftUI

struct RootPanelView: View {
    // Shared app-wide auth state, not a per-panel instance — see AuthViewModel.shared.
    @ObservedObject var authViewModel: AuthViewModel
    @ObservedObject var reviewViewModel: ReviewViewModel
    let config: BombSquadConfig.Snapshot
    @State private var didAutoReviewAfterLogin = false

    @MainActor
    init(
        reviewViewModel: ReviewViewModel,
        config: BombSquadConfig.Snapshot = BombSquadConfig.snapshot()
    ) {
        self.reviewViewModel = reviewViewModel
        self.authViewModel = .shared
        self.config = config
    }

    @MainActor
    init(
        reviewViewModel: ReviewViewModel,
        authViewModel: AuthViewModel,
        config: BombSquadConfig.Snapshot = BombSquadConfig.snapshot()
    ) {
        self.reviewViewModel = reviewViewModel
        self.authViewModel = authViewModel
        self.config = config
    }

    var body: some View {
        Group {
            if authViewModel.hasSession {
                if reviewViewModel.navigatorActiveTask != nil {
                    // Guided navigation: the whole panel becomes the corner
                    // strip; the screen being navigated is the real UI.
                    CopilotStripView(viewModel: reviewViewModel)
                } else {
                    ContentView(viewModel: reviewViewModel)
                }
            } else {
                LoginRequiredView(viewModel: authViewModel, config: config)
            }
        }
        .panelChrome()
        .onChange(of: authViewModel.hasSession) { _, isLoggedIn in
            guard isLoggedIn else { return }
            guard reviewViewModel.mode == .transform else { return }
            guard reviewViewModel.result == nil else { return }
            guard !reviewViewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard !didAutoReviewAfterLogin else { return }

            didAutoReviewAfterLogin = true
            Task { await reviewViewModel.runReview() }
        }
    }
}
