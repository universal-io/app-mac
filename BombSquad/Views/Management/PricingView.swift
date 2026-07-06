import AppKit
import SwiftUI

/// Pricing section. In-app billing UI is a later phase; for now this is just an
/// entry point that opens the web pricing page in the browser.
struct PricingView: View {
    private static let pricingURL = URL(string: "https://universal-io.com/pricing")!

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "creditcard")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("料金プラン")
                .font(.title2.weight(.semibold))
            Text("プランの詳細とアップグレードは Web で確認できます。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSWorkspace.shared.open(Self.pricingURL)
            } label: {
                Label("料金プランを見る", systemImage: "arrow.up.forward.square")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("料金プラン")
    }
}
