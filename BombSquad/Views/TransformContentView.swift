import SwiftUI

struct TransformContentView: View {
    @ObservedObject var session: PanelSession

    private var focusedField: Binding<FocusField?> {
        Binding(
            get: { session.viewModel.focusedField },
            set: { session.viewModel.focusedField = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            StagingEditorView(session: session, viewModel: session.viewModel, focusedField: focusedField)
            ReviewPanelView(
                viewModel: session.viewModel,
                focusedField: focusedField
            )
                .frame(maxHeight: .infinity)
        }
        .animation(.spring(duration: 0.35), value: session.viewModel.isLoading)
        .frame(minWidth: 620, minHeight: 640)
        .onAppear {
            DispatchQueue.main.async {
                session.markDraftFocusedIfNeeded()
            }
        }
    }
}
