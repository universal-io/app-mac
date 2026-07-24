import SwiftUI

/// Shown inside the capture panel when there is no session. Rather than bounce
/// the user to the management window, it presents the sign-in controls (Google
/// / email) right here so one Google tap gets them straight in.
struct LoginRequiredView: View {
    @ObservedObject var viewModel: AuthViewModel
    let config: BombSquadConfig.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ログイン / 新規登録")
                .font(.title2.weight(.semibold))

            SignInForm(viewModel: viewModel)

            if let statusMessage = viewModel.statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let infoMessage = viewModel.infoMessage {
                Label(infoMessage, systemImage: "info.circle")
                    .foregroundStyle(.secondary).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage = viewModel.errorMessage {
                VStack(alignment: .leading, spacing: 3) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                    if let detail = viewModel.errorDetail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
