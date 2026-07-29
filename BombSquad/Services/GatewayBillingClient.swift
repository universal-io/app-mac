import Foundation

/// Client for the billing portal endpoint (POST /api/billing/portal).
///
/// The app never talks to Stripe and holds no publishable key or price id: the
/// gateway creates a customer portal session and returns its URL, which is then
/// opened in the browser. Cancellation, payment-method changes and invoices are
/// Stripe's own screens and are not reimplemented here.
/// Transport/error plumbing lives in `GatewayClient`.
struct GatewayBillingClient {
    private let client: GatewayClient

    static func make() -> GatewayBillingClient? {
        guard let client = GatewayClient.make() else { return nil }
        return GatewayBillingClient(client: client)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    /// A single-use Stripe customer portal URL. The gateway answers 404
    /// `NO_BILLING_ACCOUNT` for an account that has never had a Stripe customer;
    /// that arrives here as the gateway's own user-facing message.
    func portalURL() async throws -> URL {
        let data = try await client.postJSON("billing/portal", body: [:])
        let envelope: PortalResponse
        do {
            envelope = try JSONDecoder().decode(PortalResponse.self, from: data)
        } catch {
            throw ProviderError.decoding("billing portal response: \(error.localizedDescription)")
        }
        guard let url = URL(string: envelope.url) else {
            throw ProviderError.decoding("billing portal returned an unusable URL")
        }
        return url
    }
}

private struct PortalResponse: Decodable {
    let url: String
}
