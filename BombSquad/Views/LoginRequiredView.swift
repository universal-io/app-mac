import SwiftUI

/// Shown inside the capture panel when there is no session. The panel stays
/// lightweight: login/signup itself lives in the management window's account
/// section, so this is just a call-to-action that opens it.
struct LoginRequiredView: View {
    @ObservedObject var viewModel: AuthViewModel
    let config: BombSquadConfig.Snapshot
    /// Opens the management window at the account section.
    let onOpenManagement: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("ログインが必要です")
                    .font(.title2.weight(.semibold))
                Text("初回利用はフリーアカウントから始まります。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                onOpenManagement()
            } label: {
                Label("ログイン / 新規登録", systemImage: "person.crop.circle")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
