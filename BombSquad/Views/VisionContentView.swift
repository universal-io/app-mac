import SwiftUI

struct VisionContentView: View {
    @ObservedObject var viewModel: ReviewViewModel

    var body: some View {
        VisionPanelView(viewModel: viewModel)
            .frame(minWidth: 900, minHeight: 600)
    }
}
