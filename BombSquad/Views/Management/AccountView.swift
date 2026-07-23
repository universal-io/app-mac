import SwiftUI

/// The account section of the management window. This is the single
/// place for sign in, sign up, and sign out: first-time use creates a free
/// account, so login and registration are the same flow here.
struct AccountView: View {
    @ObservedObject var viewModel: AuthViewModel
    /// Latest quota envelope seen on a gateway response (no extra request).
    @ObservedObject private var quotaStore = GatewayQuotaStore.shared
    let config: BombSquadConfig.Snapshot
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !config.hasSupabaseConfig {
                    notConfigured
                } else if viewModel.hasSession {
                    signedIn
                } else {
                    signedOut
                }

                statusBanner
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("アカウント")
        .alert("アカウントを削除しますか？", isPresented: $isShowingDeleteConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("退会してデータを削除", role: .destructive) {
                viewModel.deleteAccount()
            }
        } message: {
            Text("メモリ、利用記録、プロフィール、契約情報と、このMacの入力履歴・下書きを削除します。この操作は取り消せません。")
        }
    }

    // MARK: - Signed in

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(title: "アカウント", subtitle: viewModel.signedInEmail)

            GroupBox {
                VStack(spacing: 0) {
                    if let summary = viewModel.accountSummary {
                        infoRow("プラン", summary.tier.label)
                        Divider()
                        infoRow("契約状態", summary.state.label)
                        Divider()
                        infoRow("月間利用枠", "\(summary.monthlyReviewLimit) 回")
                    }
                    if let quota = quotaStore.latest {
                        Divider()
                        infoRow("今月の利用", "\(quota.used) / \(quota.limit) 回（残り \(quota.remaining) 回）")
                        Divider()
                        infoRow("次回リセット", formatResetDate(quota.resetsAt))
                    }
                    if let method = viewModel.authMethodLabel {
                        Divider()
                        infoRow("ログイン方法", method)
                    }
                    if let tenantID = viewModel.accountSummary?.tenantID ?? viewModel.tenantID {
                        Divider()
                        infoRow("テナント", redact(tenantID.uuidString))
                    }
                }
            }

            Button(role: .destructive, action: viewModel.signOut) {
                Text("ログアウト").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(viewModel.isBusy)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("退会")
                    .font(.headline)
                Text("サービス上のアカウントと関連データを削除します。有効な契約がある場合は先に解約が必要です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("アカウントを削除…", role: .destructive) {
                    isShowingDeleteConfirmation = true
                }
                .disabled(viewModel.isBusy)
            }
        }
        // Refresh summary + quota from the gateway every time the account page is
        // shown; existing values stay on screen while the request runs.
        .task {
            await viewModel.refreshAccount()
        }
    }

    // MARK: - Signed out (login / signup)

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(
                title: "ログイン / 新規登録",
                subtitle: "初回利用はフリーアカウントから始まります。"
            )

            SignInForm(viewModel: viewModel)
        }
    }

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title: "アカウント", subtitle: nil)
            Text("Supabase の URL と anon key を設定すると、ここから Bomb Squad アカウントでログインできます。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pieces

    private func header(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.weight(.semibold))
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let statusMessage = viewModel.statusMessage {
            Label(statusMessage, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let errorMessage = viewModel.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func redact(_ value: String) -> String {
        if value.count <= 12 { return value }
        return "\(value.prefix(8))...\(value.suffix(4))"
    }

    private func formatResetDate(_ iso: String) -> String {
        // The gateway emits JS toISOString() (fractional seconds); plain
        // ISO 8601 is accepted too.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }
}
