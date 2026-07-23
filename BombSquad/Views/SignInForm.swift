import SwiftUI

/// The sign-in / sign-up controls (Google + email magic link), shared by the
/// management window's account section and the capture panel's login prompt so
/// both offer the same one-tap Google / email entry. First-time use creates a
/// free account, so login and registration are the same flow.
struct SignInForm: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: viewModel.signInWithGoogle) {
                Label("Google で続ける", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canSignInWithGoogle)

            HStack {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text("または").font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(.quaternary).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("メールアドレスでログイン")
                    .font(.subheadline.weight(.medium))
                TextField("you@example.com", text: $viewModel.email)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .disabled(viewModel.isBusy)
                Button(action: viewModel.sendMagicLink) {
                    Text("ログイン用リンクを送信").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!viewModel.canSendMagicLink)
                Text("メールに届くリンクをこの Mac で開くとログインが完了します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
