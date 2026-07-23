import SwiftUI

/// Shown inside the capture panel when there is no session. Rather than bounce
/// the user to the management window, it presents the sign-in controls (Google
/// / email) right here so one Google tap gets them straight in.
struct LoginRequiredView: View {
    @ObservedObject var viewModel: AuthViewModel
    let config: BombSquadConfig.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ログイン / 新規登録")
                    .font(.title2.weight(.semibold))
                Text("初回利用はフリーアカウントから始まります。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SignInForm(viewModel: viewModel)

            if let statusMessage = viewModel.statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
