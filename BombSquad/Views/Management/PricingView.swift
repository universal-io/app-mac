import AppKit
import SwiftUI

/// The pricing section.
///
/// Plan comparison and purchase stay on the web, but cancellation has to be
/// reachable from inside the app: this is the surface that already holds an
/// authenticated session and shows the plan, and shipping a way to start paying
/// with no way to stop is not an option. The app still touches no Stripe API —
/// the gateway returns a customer portal URL and this opens it in the browser.
struct PricingView: View {
    @ObservedObject var viewModel: AuthViewModel

    private static let pricingURL = URL(string: "https://www.universal-io.com/pricing")!

    /// The portal exists only once Stripe has a customer for this tenant, which
    /// the gateway reports. An account that never paid therefore sees no button
    /// rather than one that can only answer that it has nothing to show.
    private var canManagePayment: Bool {
        viewModel.hasSession && (viewModel.accountSummary?.hasBillingAccount ?? false)
    }

    private var isPaidPlan: Bool {
        viewModel.accountSummary?.plan.isPaid ?? false
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "creditcard")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)

            Text("料金プラン")
                .font(.title2.weight(.semibold))

            if viewModel.hasSession, let summary = viewModel.accountSummary {
                Text("現在のプラン: \(summary.plan.label)（\(summary.state.label)）")
                    .foregroundStyle(.secondary)
            }

            // Said here as well as on the account page, because this is the screen
            // the user was on when they cancelled and the one they will come back
            // to if they doubt it worked.
            if let cancelAtText = viewModel.accountSummary?.cancelAtText {
                Text("\(cancelAtText)に終了予定です。それまでは今のプランのままご利用いただけます。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(canManagePayment
                 ? "解約、支払い方法の変更、請求書の確認は Stripe の画面で行います。"
                 : "プランの詳細とお申し込みは Web で確認できます。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            actions

            if let message = viewModel.billingErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("料金プラン")
        // Whether the portal can open depends on the Stripe customer link, which
        // a webhook may have written moments ago; refresh like the account page.
        .task {
            await viewModel.refreshAccount()
        }
    }

    /// A subscriber came here to manage what they already pay for, so that is
    /// their prominent action. Anyone else is here to look at the plans.
    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            if canManagePayment {
                if isPaidPlan {
                    paymentButton.buttonStyle(.borderedProminent)
                    pricingButton.buttonStyle(.bordered)
                } else {
                    pricingButton.buttonStyle(.borderedProminent)
                    paymentButton.buttonStyle(.bordered)
                }
            } else {
                pricingButton.buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }

    private var paymentButton: some View {
        Button {
            viewModel.openBillingPortal()
        } label: {
            Label(
                viewModel.isOpeningBillingPortal ? "開いています…" : "お支払い管理",
                systemImage: "arrow.up.forward.square"
            )
            .frame(maxWidth: .infinity)
        }
        .disabled(viewModel.isOpeningBillingPortal)
        .accessibilityHint("解約や支払い方法の変更を行う Stripe の画面をブラウザで開きます")
    }

    private var pricingButton: some View {
        Button {
            NSWorkspace.shared.open(Self.pricingURL)
        } label: {
            Label("料金プランを見る", systemImage: "arrow.up.forward.square")
                .frame(maxWidth: .infinity)
        }
    }
}
