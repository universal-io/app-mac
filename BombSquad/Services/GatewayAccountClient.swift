import Foundation

/// Client for the account summary endpoint (GET /api/account). The gateway is
/// the single source of truth for plan / status / usage, replacing the legacy
/// client-side Supabase reads of bs_profiles and bs_entitlements.
struct GatewayAccountClient {
    private let api: GatewayAPI
    private let session: URLSession

    static func make() -> GatewayAccountClient? {
        guard let api = GatewayAPI.make() else { return nil }
        return GatewayAccountClient(api: api)
    }

    init(api: GatewayAPI, session: URLSession = .shared) {
        self.api = api
        self.session = session
    }

    /// Fetches the account summary and publishes the bundled quota envelope to
    /// `GatewayQuotaStore`, so the my-page usage rows show without waiting for
    /// an AI operation to happen first.
    func fetchAccount() async throws -> BombSquadAccountSummary {
        let request = try await api.authorizedRequest("account", method: "GET")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.http(status: -1, body: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.http(status: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayAPI.error(status: http.statusCode, data: data)
        }

        let envelope: AccountResponse
        do {
            envelope = try JSONDecoder().decode(AccountResponse.self, from: data)
        } catch {
            throw ProviderError.decoding("account response: \(error.localizedDescription)")
        }

        GatewayQuotaStore.shared.update(envelope.quota)

        return BombSquadAccountSummary(
            email: envelope.account.email ?? "",
            tenantID: envelope.account.tenantID,
            tier: .fromEntitlementPlan(envelope.account.plan),
            state: .fromRawValue(envelope.account.status),
            monthlyReviewLimit: envelope.account.monthlyReviewLimit
        )
    }
}

private struct AccountResponse: Decodable {
    struct Account: Decodable {
        // The gateway emits null when the auth provider carries no email.
        let email: String?
        let tenantID: UUID
        let plan: String
        let status: String
        let monthlyReviewLimit: Int

        private enum CodingKeys: String, CodingKey {
            case email, plan, status
            case tenantID = "tenant_id"
            case monthlyReviewLimit = "monthly_review_limit"
        }
    }

    let account: Account
    let quota: GatewayQuota
}
