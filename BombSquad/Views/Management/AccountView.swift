import SwiftUI

/// The account / "my page" section of the management window. This is the single
/// place for sign in, sign up, and sign out: first-time use creates a free
/// account, so login and registration are the same flow here.
struct AccountView: View {
    @ObservedObject var viewModel: AuthViewModel
    /// Latest quota envelope seen on a gateway response (no extra request).
    @ObservedObject private var quotaStore = GatewayQuotaStore.shared
    let config: BombSquadConfig.Snapshot

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
    }

    // MARK: - Signed in (my page)

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(title: "マイページ", subtitle: viewModel.signedInEmail)

            GroupBox {
                VStack(spacing: 0) {
                    if let summary = viewModel.accountSummary {
                        infoRow("プラン", summary.tier.label)
                        Divider()
                        infoRow("契約状態", summary.state.label)
                        Divider()
                        infoRow("月間利用枠", summary.monthlyReviewLimit.map { "\($0) 回" } ?? "無制限")
                    }
                    if let quota = quotaStore.latest {
                        Divider()
                        if let limit = quota.limit, let remaining = quota.remaining {
                            infoRow("今月の利用", "\(quota.used) / \(limit) 回（残り \(remaining) 回）")
                        } else {
                            infoRow("今月の利用", "\(quota.used) 回（無制限）")
                        }
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
        }
        // Refresh summary + quota from the gateway every time the my page is
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
