import SwiftUI

struct ComposeContentView: View {
    @ObservedObject var session: PanelSession

    private var viewModel: ReviewViewModel { session.viewModel }
    private var isResultActive: Bool { viewModel.result != nil || viewModel.isLoading }
    private var focusedField: Binding<FocusField?> {
        Binding(
            get: { session.viewModel.focusedField },
            set: { session.viewModel.focusedField = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            StagingEditorView(session: session, viewModel: viewModel, focusedField: focusedField)
                .frame(maxHeight: isResultActive ? 190 : .infinity)
            ReviewPanelView(
                viewModel: viewModel,
                focusedField: focusedField
            )
                .frame(maxHeight: .infinity)
        }
        .animation(.spring(duration: 0.35), value: isResultActive)
        .frame(minWidth: 620, minHeight: 640)
        .onAppear {
            DispatchQueue.main.async {
                session.markDraftFocusedIfNeeded()
            }
        }
    }
}
