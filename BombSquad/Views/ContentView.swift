import SwiftUI

/// Which editor currently has focus. Drives the blue focus highlight and
/// determines which side gets deployed.
enum FocusField: Hashable {
    case draft     // top: original
    case revision  // bottom: review result
    case navigator // vision panel: navigator question input
}

/// Root text layout: a single Spotlight-style column — input on top, result
/// below. Three states only: empty → draft → result (design principle 3.5).
/// The right-Shift single tap moves focus between the two editors (top ↔ bottom).
struct ContentView: View {
    @StateObject private var viewModel: ReviewViewModel

    /// Defaults to a clipboard-deploying view model (standalone window). The
    /// hotkey panel injects a `PasteDeployer`-backed one.
    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: ReviewViewModel())
    }

    @MainActor
    init(viewModel: @autoclosure @escaping () -> ReviewViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    /// True once the bottom area holds live content (spinner or result), at
    /// which point the input yields most of the vertical space to it.
    private var isResultActive: Bool {
        viewModel.result != nil || viewModel.isLoading
    }

    var body: some View {
        // Keep this Group as the body's root: wrapping it in a VStack changed
        // the view identity and reset the SendableTextEditor's first responder,
        // which broke Enter-to-deploy. The dev-gateway indicator lives as a
        // small GatewayOverrideBadge in each header's model-info row, not as
        // a full-width banner here.
        Group {
            VStack(spacing: 0) {
                StagingEditorView(session: nil, viewModel: viewModel, focusedField: $viewModel.focusedField)
                    .frame(maxHeight: isResultActive ? 190 : .infinity)
                ReviewPanelView(viewModel: viewModel, focusedField: $viewModel.focusedField)
                    .frame(maxHeight: .infinity)
            }
            .animation(.spring(duration: 0.35), value: isResultActive)
            .frame(minWidth: 620, minHeight: 640)
        }
        .onAppear {
            // Defer so the panel is key before focusing the original editor.
            DispatchQueue.main.async {
                viewModel.focusedField = .draft
            }
        }
    }
}
