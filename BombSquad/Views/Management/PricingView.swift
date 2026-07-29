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

    private var isCancelling: Bool {
        viewModel.accountSummary?.cancelAt != nil
    }

    /// Names what the user came to do, not the screen it opens.
    ///
    /// "お支払い管理" was tested and failed: the person who wanted to cancel could
    /// not tell that this was the way to do it. The portal does handle payment
    /// methods and invoices too, but cancelling is the errand nobody can guess, so
    /// it gets the label and the rest goes in the caption. The trailing ellipsis is
    /// the macOS convention for a command that needs more input before it completes
    /// — clicking this opens Stripe, it does not cancel anything by itself.
    private var paymentButtonTitle: String {
        if !isPaidPlan { return "請求書・お支払い方法…" }
        if isCancelling { return "解約の取り消し・お支払い方法…" }
        return "サブスクリプションを解約…"
    }

    /// Names the other things the portal does, so the button can be about the one
    /// thing that needed naming.
    private var description: String {
        guard canManagePayment else {
            return "プランの詳細とお申し込みは Web で確認できます。"
        }
        return isPaidPlan && !isCancelling
            ? "解約は Stripe の画面で行います。支払い方法の変更と請求書の確認も同じ画面です。"
            : "支払い方法の変更と請求書の確認は Stripe の画面で行います。"
    }

    private var paymentButtonHint: String {
        isPaidPlan && !isCancelling
            ? "解約手続きを行う Stripe の画面をブラウザで開きます"
            : "支払い方法の変更や請求書の確認を行う Stripe の画面をブラウザで開きます"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "creditcard")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)

            Text("料金プラン")
                .font(.title2.weight(.semibold))

            if viewModel.hasSession, let summary = viewModel.accountSummary {
                Text("現在のプラン: \(summary.plan.label)")
                    .foregroundStyle(.secondary)

                // Only when it says something the plan name does not. A cancelled
                // or past-due subscription needs stating here, not just on the
                // account page: this is the screen the user cancelled from and the
                // one they come back to if they doubt it worked. A plain active
                // plan needs no second line.
                if summary.cancelAt != nil || summary.state != .active {
                    Text(summary.stateText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(description)
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
        // This is the screen a purchase starts from — the web pricing page is one
        // click away — so it is also where the user returns expecting to see what
        // they bought.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            viewModel.refreshAfterExternalBillingChange()
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
                viewModel.isOpeningBillingPortal ? "開いています…" : paymentButtonTitle,
                systemImage: "arrow.up.forward.square"
            )
            .frame(maxWidth: .infinity)
        }
        .disabled(viewModel.isOpeningBillingPortal)
        .accessibilityHint(paymentButtonHint)
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
