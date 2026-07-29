import AppKit
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
                        infoRow("プラン", summary.plan.label)
                        Divider()
                        // Carries the cancellation and its end date when there is
                        // one: a cancelled plan stays `active` for weeks, so the
                        // bare status would look like nothing happened.
                        infoRow("契約状態", summary.stateText)
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
        // And again whenever the user comes back to the app with this page open.
        // Buying and cancelling both finish in a browser, so the plan on screen is
        // stale exactly when it matters most — a subscriber who just paid and reads
        // "フリー" here has every reason to think the payment was lost.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            viewModel.refreshAfterExternalBillingChange()
        }
    }

    // MARK: - Signed out (login / signup)

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(
                title: "ログイン / 新規登録",
                subtitle: nil
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
        if let infoMessage = viewModel.infoMessage {
            Label(infoMessage, systemImage: "info.circle")
                .foregroundStyle(.secondary)
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
        GatewayTimestamp.dayText(fromISO: iso)
    }
}
